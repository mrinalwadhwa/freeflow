import AVFoundation
import AppKit
import FreeFlowKit
import OSLog

/// Provide audio capture for mic preview during onboarding.
protocol AudioPreviewProviding: AnyObject {
    func startRecording() async throws
    func stopRecording() async throws -> FreeFlowKit.AudioBuffer
    var audioLevelStream: AsyncStream<Float>? { get }
}

extension AudioCaptureProvider: AudioPreviewProviding {}

/// Coordinate bridge actions from the onboarding web pages with native
/// services. Each bridge action is handled by calling the appropriate
/// service (Keychain, auth client, permissions) and pushing the result
/// back to the web page via the bridge.
///
/// The controller owns the OnboardingWindow and OnboardingBridge. It is
/// created by AppDelegate when onboarding is needed and dismissed when
/// the user completes the flow.
@MainActor
final class OnboardingController {

    private let keychain: KeychainService
    private let authClient: AuthClient
    private let capabilitiesService: CapabilitiesService
    private let config: ServiceConfig

    private let bridge: OnboardingBridge
    private(set) var window: OnboardingWindow?

    /// Called when onboarding completes successfully. AppDelegate uses
    /// this to register the hotkey and transition to the active state.
    var onComplete: (() -> Void)?

    /// Called when the user needs to register the hotkey during the
    /// try-it onboarding step. AppDelegate wires this to its own
    /// registerHotkey method.
    var onRegisterHotkey: (() -> Void)?

    /// Called when a dictation result should be pushed to the try-it
    /// screen. AppDelegate wires the pipeline to call this.
    var onDictationResult: ((_ text: String) -> Void)?

    /// The accessibility permission provider, set by AppDelegate.
    var permissionProvider: (any PermissionProviding)?

    /// The audio device provider for mic selection, set by AppDelegate.
    var audioDeviceProvider: CoreAudioDeviceProvider?

    /// The audio capture provider for mic preview, set by AppDelegate.
    var audioPreviewProvider: AudioPreviewProviding?

    /// The sound feedback provider, set by AppDelegate. Used to mute
    /// start/stop cues during mic preview so onboarding is silent.
    var soundFeedbackProvider: SoundFeedbackProvider?

    /// Polling timer for accessibility permission checks.
    private var accessibilityPollTimer: Timer?

    /// Called when the user chooses the admin setup path from the
    /// onboarding entry chooser. AppDelegate wires this to open the
    /// native provisioning flow.
    var onStartAdminSetup: (() -> Void)?

    /// Task for streaming audio levels during mic preview.
    private var audioLevelTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        keychain: KeychainService = KeychainService(),
        authClient: AuthClient = AuthClient(),
        capabilitiesService: CapabilitiesService = CapabilitiesService(),
        config: ServiceConfig = .shared
    ) {
        self.keychain = keychain
        self.authClient = authClient
        self.capabilitiesService = capabilitiesService
        self.config = config
        self.bridge = OnboardingBridge()

        setupBridgeHandlers()
    }

    // MARK: - Window management

    /// Open the onboarding window and navigate to the given path.
    ///
    /// If the window already exists, it navigates to the new path
    /// without recreating it. When no service URL is configured yet
    /// (fresh install before an invite link is clicked), the window
    /// is presented empty and waits for a `freeflow://connect` URL to
    /// provide the service URL.
    ///
    /// - Parameter path: The path to load, e.g. `/onboarding/?token=abc`.
    func showWindow(path: String) {
        if window == nil {
            let win = OnboardingWindow(bridge: bridge)
            bridge.webView = win.webView
            window = win
        }

        let baseURL = config.baseURL
        // Only navigate if we have a real service URL. The localhost
        // fallback means no Keychain URL and no env var, so the zone
        // is unreachable. Show a placeholder page until handleConnectURL
        // stores a service URL and navigates.
        if !baseURL.contains("localhost") {
            window?.navigate(baseURL: baseURL, path: path)
        } else {
            window?.loadWaitingPlaceholder()
        }
        window?.present()
    }

    /// Open the onboarding flow for a freeflow:// connect URL.
    ///
    /// Parses the URL, stores the service URL in the Keychain, and
    /// opens the onboarding page with the invite token.
    func handleConnectURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "freeflow",
            components.host == "connect"
        else {
            return
        }

        let params = components.queryItems ?? []
        let serviceURL = params.first(where: { $0.name == "url" })?.value
        let token = params.first(where: { $0.name == "token" })?.value

        if let serviceURL, !serviceURL.isEmpty {
            keychain.saveServiceURL(serviceURL)
        }

        let tokenParam = token.map { "?token=\($0)" } ?? ""
        showWindow(path: "/onboarding/\(tokenParam)")
    }

    /// Show the add-email page in the onboarding window.
    ///
    /// - Parameter variant: The variant query parameter (voluntary, grace, enforced).
    func showAddEmail(variant: String = "voluntary") {
        showWindow(path: "/account/add-email?variant=\(variant)")
    }

    /// Show the sign-in page for session recovery.
    ///
    /// - Parameter email: The user's email to pre-fill.
    func showSignIn(email: String? = nil) {
        var path = "/account/sign-in"
        if let email, !email.isEmpty {
            let encoded =
                email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            path += "?email=\(encoded)"
        }
        showWindow(path: path)
    }

    /// Dismiss the onboarding window and clean up.
    func dismissWindow() {
        stopAccessibilityPolling()
        handleStopMicPreview()
        window?.dismiss()
        window = nil
    }

    // MARK: - Bridge action handlers

    private func setupBridgeHandlers() {
        bridge.onRedeemInvite = { [weak self] token in
            self?.handleRedeemInvite(token: token)
        }

        bridge.onStoreToken = { [weak self] token in
            self?.handleStoreToken(token: token)
        }

        bridge.onEmailAdded = { [weak self] email in
            self?.handleEmailAdded(email: email)
        }

        bridge.onCheckAccessibility = { [weak self] in
            self?.handleCheckAccessibility()
        }

        bridge.onOpenAccessibilitySettings = { [weak self] in
            self?.handleOpenAccessibilitySettings()
        }

        bridge.onRequestMicrophone = { [weak self] in
            self?.handleRequestMicrophone()
        }

        bridge.onListMicrophones = { [weak self] in
            self?.handleListMicrophones()
        }

        bridge.onSelectMicrophone = { [weak self] id in
            self?.handleSelectMicrophone(id: id)
        }

        bridge.onStartMicPreview = { [weak self] in
            self?.handleStartMicPreview()
        }

        bridge.onStopMicPreview = { [weak self] in
            self?.handleStopMicPreview()
        }

        bridge.onRegisterHotkey = { [weak self] in
            self?.handleRegisterHotkey()
        }

        bridge.onOpenProvisioning = { [weak self] in
            self?.handleStartAdminSetup()
        }

        bridge.onCompleteOnboarding = { [weak self] in
            self?.handleCompleteOnboarding()
        }

        // Wire dictation results back to the bridge.
        onDictationResult = { [weak self] text in
            self?.bridge.pushDictationResult(text: text)
        }
    }

    // MARK: - Action: redeemInvite

    private func handleRedeemInvite(token: String) {
        Task {
            do {
                let serviceURL = config.baseURL
                let result = try await authClient.redeemInvite(
                    serviceURL: serviceURL,
                    token: token
                )

                // Store credentials in Keychain.
                keychain.saveSessionToken(result.sessionToken)
                keychain.saveServiceURL(serviceURL)

                // Track email status.
                if result.hasEmail {
                    UserDefaults.standard.set(true, forKey: "hasEmailOnFile")
                }

                bridge.pushInviteRedeemed(
                    userId: result.userId,
                    hasEmail: result.hasEmail
                )
            } catch {
                let message: String
                if let authError = error as? AuthClient.AuthError {
                    switch authError {
                    case .serverError(_, let detail):
                        // Try to extract the "detail" field from the JSON error.
                        if let data = detail.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                            let detailMsg = json["detail"] as? String
                        {
                            message = detailMsg
                        } else {
                            message = detail
                        }
                    case .missingSessionToken:
                        message = "Server did not return a session token."
                    default:
                        message = error.localizedDescription
                    }
                } else {
                    message = error.localizedDescription
                }
                bridge.pushInviteRedeemFailed(error: message)
            }
        }
    }

    // MARK: - Action: storeToken

    private func handleStoreToken(token: String) {
        keychain.saveSessionToken(token)
        bridge.pushTokenStored()
    }

    // MARK: - Action: emailAdded

    private func handleEmailAdded(email: String) {
        UserDefaults.standard.set(true, forKey: "hasEmailOnFile")
        keychain.saveUserEmail(email)
    }

    // MARK: - Action: startAdminSetup

    private func handleStartAdminSetup() {
        onStartAdminSetup?()
    }

    // MARK: - Action: listMicrophones

    private func handleListMicrophones() {
        guard let audioDeviceProvider else { return }
        Task {
            let devices = await audioDeviceProvider.availableDevices()
            let current = await audioDeviceProvider.currentDevice()

            let deviceList: [[String: Any]] = devices.map { device in
                [
                    "id": device.id,
                    "name": device.name,
                    "isDefault": device.isDefault,
                ]
            }

            bridge.pushMicrophoneList(
                devices: deviceList,
                currentId: current?.id
            )
        }
    }

    // MARK: - Action: selectMicrophone

    private func handleSelectMicrophone(id: UInt32) {
        guard let audioDeviceProvider, let audioPreviewProvider else { return }
        Task {
            do {
                // Stop current preview and wait for it to complete.
                await stopMicPreviewAsync()

                // Select the new device.
                try await audioDeviceProvider.selectDevice(id: id)
                NSLog("[OnboardingController] Selected mic id=%d", id)
                bridge.pushMicrophoneSelected(id: id)

                // Small delay to let the audio system settle after device change.
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                // Start preview with the new device.
                await startMicPreviewAsync()
            } catch {
                NSLog("[OnboardingController] selectMicrophone failed: %@", "\(error)")
            }
        }
    }

    // MARK: - Action: startMicPreview

    private func handleStartMicPreview() {
        Task {
            await startMicPreviewAsync()
        }
    }

    private func startMicPreviewAsync() async {
        guard let audioPreviewProvider else {
            NSLog("[OnboardingController] startMicPreview: no audioPreviewProvider")
            return
        }

        // Stop any existing preview first.
        await stopMicPreviewAsync()

        do {
            // Mute sound feedback during preview so the mic selection
            // step does not play the start/stop cues.
            if let capture = audioPreviewProvider as? AudioCaptureProvider {
                capture.setSoundFeedbackProvider(nil)
            }

            NSLog("[OnboardingController] Starting mic preview")
            try await audioPreviewProvider.startRecording()
            NSLog("[OnboardingController] Mic preview started, setting up level stream")

            // Stream audio levels to the bridge.
            audioLevelTask = Task { [weak self] in
                guard let stream = audioPreviewProvider.audioLevelStream else {
                    NSLog("[OnboardingController] No audio level stream available")
                    return
                }
                NSLog("[OnboardingController] Audio level stream started")
                for await level in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.bridge.pushAudioLevel(level: level)
                    }
                }
                NSLog("[OnboardingController] Audio level stream ended")
            }
        } catch {
            NSLog("[OnboardingController] startMicPreview failed: %@", "\(error)")
        }
    }

    // MARK: - Action: stopMicPreview

    private func handleStopMicPreview() {
        Task {
            await stopMicPreviewAsync()
        }
    }

    private func stopMicPreviewAsync() async {
        audioLevelTask?.cancel()
        audioLevelTask = nil

        guard let audioPreviewProvider else { return }
        NSLog("[OnboardingController] Stopping mic preview")
        _ = try? await audioPreviewProvider.stopRecording()
        // Restore sound feedback after preview stops.
        if let soundFeedbackProvider,
            let capture = audioPreviewProvider as? AudioCaptureProvider
        {
            capture.setSoundFeedbackProvider(soundFeedbackProvider)
        }
        NSLog("[OnboardingController] Mic preview stopped")
    }

    // MARK: - Action: checkAccessibility

    private func handleCheckAccessibility() {
        let granted = permissionProvider?.checkAccessibility() == .granted

        // Check the actual system microphone authorization status rather
        // than relying on a UserDefaults flag that may not be set if the
        // permission was granted outside the onboarding flow.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micGranted = micStatus == .authorized
        if micGranted {
            UserDefaults.standard.set(true, forKey: "microphoneGranted")
        }

        NSLog(
            "[OnboardingController] checkAccessibility: ax=%@, mic=%@",
            granted ? "granted" : "denied",
            micGranted ? "granted" : (micStatus == .denied ? "denied" : "unknown"))

        bridge.pushPermissionStatus(
            accessibility: granted ? "granted" : "denied",
            microphone: micGranted ? "granted" : (micStatus == .denied ? "denied" : "unknown")
        )

        // Start polling every 2s until granted.
        if !granted {
            startAccessibilityPolling()
        }
    }

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        accessibilityPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAccessibility()
            }
        }
    }

    private func stopAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
    }

    private func pollAccessibility() {
        let granted = permissionProvider?.checkAccessibility() == .granted

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micGranted = micStatus == .authorized
        if micGranted {
            UserDefaults.standard.set(true, forKey: "microphoneGranted")
        }

        bridge.pushPermissionStatus(
            accessibility: granted ? "granted" : "denied",
            microphone: micGranted ? "granted" : (micStatus == .denied ? "denied" : "unknown")
        )

        if granted {
            stopAccessibilityPolling()
        }
    }

    // MARK: - Action: openAccessibilitySettings

    private func handleOpenAccessibilitySettings() {
        permissionProvider?.openAccessibilitySettings()
    }

    // MARK: - Action: requestMicrophone

    private func handleRequestMicrophone() {
        Task {
            let granted = await requestMicrophoneAccess()

            if granted {
                UserDefaults.standard.set(true, forKey: "microphoneGranted")
            }

            NSLog(
                "[OnboardingController] requestMicrophone result: %@",
                granted ? "granted" : "denied")

            let accGranted = permissionProvider?.checkAccessibility() == .granted
            bridge.pushPermissionStatus(
                accessibility: accGranted ? "granted" : "denied",
                microphone: granted ? "granted" : "denied"
            )
        }
    }

    private func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Action: registerHotkey

    private func handleRegisterHotkey() {
        onRegisterHotkey?()
    }

    // MARK: - Action: completeOnboarding

    private func handleCompleteOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        dismissWindow()
        onComplete?()
    }
}
