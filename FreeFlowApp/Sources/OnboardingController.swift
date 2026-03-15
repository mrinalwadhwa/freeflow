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

    /// Open the onboarding window and load the bundled onboarding page.
    ///
    /// The onboarding page is a self-contained HTML file shipped in the
    /// app bundle. It does not depend on the zone server. Query
    /// parameters (e.g. `?token=abc`, `?skip=connect`) are appended to
    /// the file URL so the page JS can read them with
    /// `URLSearchParams(window.location.search)`.
    ///
    /// - Parameter path: Query string portion, e.g. `/onboarding/?token=abc`.
    ///   Only the query parameters are used; the path component is ignored
    ///   because the page always loads from the bundle.
    func showWindow(path: String) {
        if window == nil {
            let win = OnboardingWindow(bridge: bridge)
            bridge.webView = win.webView
            window = win
        }

        window?.loadBundledOnboarding(queryString: extractQuery(from: path))
        window?.present()
    }

    /// Extract the query string from a path like `/onboarding/?token=abc`.
    private func extractQuery(from path: String) -> String? {
        guard let questionMark = path.firstIndex(of: "?") else { return nil }
        let query = String(path[path.index(after: questionMark)...])
        return query.isEmpty ? nil : query
    }

    /// Open the onboarding flow for a freeflow:// connect URL.
    ///
    /// Parses the URL, stores the service URL in the Keychain, and
    /// opens the bundled onboarding page with the invite token.
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
    /// Loads the bundled add-email page from the app bundle. The
    /// variant query parameter controls the UI tone (voluntary, grace,
    /// enforced). All HTTP calls go through the native bridge.
    ///
    /// - Parameter variant: The variant query parameter (voluntary, grace, enforced).
    func showAddEmail(variant: String = "voluntary") {
        ensureWindow()
        window?.loadBundledPage("add-email", queryString: "variant=\(variant)")
        window?.present()
    }

    /// Show the sign-in page for session recovery.
    ///
    /// Loads the bundled sign-in page from the app bundle. The email
    /// parameter pre-fills the input field. All HTTP calls go through
    /// the native bridge.
    ///
    /// - Parameter email: The user's email to pre-fill.
    func showSignIn(email: String? = nil) {
        ensureWindow()
        var queryString = ""
        if let email, !email.isEmpty {
            let encoded =
                email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
            queryString = "email=\(encoded)"
        }
        window?.loadBundledPage("sign-in", queryString: queryString.isEmpty ? nil : queryString)
        window?.present()
    }

    /// Ensure the onboarding window exists, creating it if needed.
    private func ensureWindow() {
        if window == nil {
            let win = OnboardingWindow(bridge: bridge)
            bridge.webView = win.webView
            window = win
        }
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

        // Account page actions (add-email flow)
        bridge.onChangeEmail = { [weak self] email, callbackURL in
            self?.handleChangeEmail(email: email, callbackURL: callbackURL)
        }

        bridge.onVerifyEmailOtp = { [weak self] email, otp in
            self?.handleVerifyEmailOtp(email: email, otp: otp)
        }

        // Account page actions (sign-in flow)
        bridge.onSendSignInOtp = { [weak self] email, type in
            self?.handleSendSignInOtp(email: email, type: type)
        }

        bridge.onSignInWithOtp = { [weak self] email, otp in
            self?.handleSignInWithOtp(email: email, otp: otp)
        }

        bridge.onDismiss = { [weak self] in
            self?.handleDismiss()
        }

        bridge.onSignInComplete = { [weak self] in
            self?.handleSignInComplete()
        }

        bridge.onEmailAddedComplete = { [weak self] in
            self?.handleEmailAddedComplete()
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

    // MARK: - Action: changeEmail (add-email flow)

    /// Handle the changeEmail bridge action by making an HTTP request
    /// to the zone's change-email endpoint and pushing the result back.
    private func handleChangeEmail(email: String, callbackURL: String) {
        Task {
            do {
                let result = try await zoneAuthRequest(
                    path: "/api/auth/change-email",
                    body: [
                        "newEmail": email,
                        "callbackURL": callbackURL,
                    ]
                )
                // Success: the zone sent a verification OTP to the email.
                _ = result
                bridge.pushChangeEmailResult()
            } catch {
                bridge.pushChangeEmailResult(error: extractErrorMessage(error))
            }
        }
    }

    // MARK: - Action: verifyEmailOtp (add-email flow)

    /// Handle the verifyEmailOtp bridge action by making an HTTP
    /// request to the zone's verify-email endpoint.
    private func handleVerifyEmailOtp(email: String, otp: String) {
        Task {
            do {
                let result = try await zoneAuthRequest(
                    path: "/api/auth/email-otp/verify-email",
                    body: [
                        "email": email,
                        "otp": otp,
                    ]
                )
                _ = result
                bridge.pushVerifyEmailOtpResult()
            } catch {
                bridge.pushVerifyEmailOtpResult(error: extractErrorMessage(error))
            }
        }
    }

    // MARK: - Action: sendSignInOtp (sign-in flow)

    /// Handle the sendSignInOtp bridge action by making an HTTP
    /// request to the zone's send-verification-otp endpoint.
    private func handleSendSignInOtp(email: String, type: String) {
        Task {
            do {
                let result = try await zoneAuthRequest(
                    path: "/api/auth/email-otp/send-verification-otp",
                    body: [
                        "email": email,
                        "type": type,
                    ]
                )
                _ = result
                bridge.pushSendSignInOtpResult()
            } catch {
                bridge.pushSendSignInOtpResult(error: extractErrorMessage(error))
            }
        }
    }

    // MARK: - Action: signInWithOtp (sign-in flow)

    /// Handle the signInWithOtp bridge action by making an HTTP
    /// request to the zone's sign-in endpoint. Extracts the session
    /// token from the response header and stores it in the Keychain.
    private func handleSignInWithOtp(email: String, otp: String) {
        Task {
            do {
                let serviceURL = config.baseURL
                guard
                    let url = URL(
                        string: "\(serviceURL)/api/auth/sign-in/email-otp")
                else {
                    bridge.pushSignInWithOtpResult(error: "Invalid URL")
                    return
                }

                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(
                    "application/json",
                    forHTTPHeaderField: "Content-Type")

                // Include session token if available for authenticated
                // sign-in requests.
                if let token = keychain.sessionToken(), !token.isEmpty {
                    request.setValue(
                        "Bearer \(token)",
                        forHTTPHeaderField: "Authorization")
                }

                request.httpBody = try JSONSerialization.data(
                    withJSONObject: [
                        "email": email,
                        "otp": otp,
                    ])

                let (data, response) = try await URLSession.shared.data(
                    for: request)

                guard let httpResponse = response as? HTTPURLResponse
                else {
                    bridge.pushSignInWithOtpResult(
                        error: "Invalid response")
                    return
                }

                if httpResponse.statusCode != 200 {
                    let errorMsg =
                        extractServerError(from: data)
                        ?? "Sign-in failed"
                    bridge.pushSignInWithOtpResult(error: errorMsg)
                    return
                }

                // Extract the session token from the set-auth-token
                // header (better-auth bearer plugin behavior).
                if let token = httpResponse.value(
                    forHTTPHeaderField: "set-auth-token"),
                    !token.isEmpty
                {
                    keychain.saveSessionToken(token)
                }

                bridge.pushSignInWithOtpResult()
            } catch {
                bridge.pushSignInWithOtpResult(
                    error: extractErrorMessage(error))
            }
        }
    }

    // MARK: - Action: dismiss

    private func handleDismiss() {
        window?.orderOut(nil)
    }

    // MARK: - Action: signInComplete

    private func handleSignInComplete() {
        dismissWindow()
        onComplete?()
    }

    // MARK: - Action: emailAddedComplete

    private func handleEmailAddedComplete() {
        dismissWindow()
        onComplete?()
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
                #if DEBUG
                    Log.debug("[OnboardingController] Selected mic id=\(id)")
                #endif
                bridge.pushMicrophoneSelected(id: id)

                // Small delay to let the audio system settle after device change.
                try await Task.sleep(nanoseconds: 100_000_000)  // 100ms

                // Start preview with the new device.
                await startMicPreviewAsync()
            } catch {
                #if DEBUG
                    Log.debug("[OnboardingController] selectMicrophone failed: \(error)")
                #endif
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
            #if DEBUG
                Log.debug("[OnboardingController] startMicPreview: no audioPreviewProvider")
            #endif
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

            #if DEBUG
                Log.debug("[OnboardingController] Starting mic preview")
            #endif
            try await audioPreviewProvider.startRecording()
            #if DEBUG
                Log.debug("[OnboardingController] Mic preview started, setting up level stream")
            #endif

            // Stream audio levels to the bridge.
            audioLevelTask = Task { [weak self] in
                guard let stream = audioPreviewProvider.audioLevelStream else {
                    #if DEBUG
                        Log.debug("[OnboardingController] No audio level stream available")
                    #endif
                    return
                }
                #if DEBUG
                    Log.debug("[OnboardingController] Audio level stream started")
                #endif
                for await level in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.bridge.pushAudioLevel(level: level)
                    }
                }
                #if DEBUG
                    Log.debug("[OnboardingController] Audio level stream ended")
                #endif
            }
        } catch {
            #if DEBUG
                Log.debug("[OnboardingController] startMicPreview failed: \(error)")
            #endif
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
        #if DEBUG
            Log.debug("[OnboardingController] Stopping mic preview")
        #endif
        _ = try? await audioPreviewProvider.stopRecording()
        // Restore sound feedback after preview stops.
        if let soundFeedbackProvider,
            let capture = audioPreviewProvider as? AudioCaptureProvider
        {
            capture.setSoundFeedbackProvider(soundFeedbackProvider)
        }
        #if DEBUG
            Log.debug("[OnboardingController] Mic preview stopped")
        #endif
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

        #if DEBUG
            Log.debug(
                "[OnboardingController] checkAccessibility: ax=\(granted ? "granted" : "denied"), mic=\(micGranted ? "granted" : (micStatus == .denied ? "denied" : "unknown"))"
            )
        #endif

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

            #if DEBUG
                Log.debug(
                    "[OnboardingController] requestMicrophone result: \(granted ? "granted" : "denied")"
                )
            #endif

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

    // MARK: - Zone auth HTTP helpers

    /// Make an authenticated POST request to a zone auth endpoint and
    /// return the response data.
    ///
    /// Includes the session token from the Keychain as a Bearer header
    /// if available, matching the `credentials: "same-origin"` behavior
    /// of the original fetch calls.
    private func zoneAuthRequest(
        path: String,
        body: [String: Any]
    ) async throws -> Data {
        let serviceURL = config.baseURL
        guard let url = URL(string: "\(serviceURL)\(path)") else {
            throw ZoneAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json", forHTTPHeaderField: "Content-Type")

        // Include session token if available.
        if let token = keychain.sessionToken(), !token.isEmpty {
            request.setValue(
                "Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONSerialization.data(
            withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(
            for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ZoneAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let detail =
                extractServerError(from: data)
                ?? "Request failed (HTTP \(httpResponse.statusCode))"
            throw ZoneAuthError.serverError(detail)
        }

        return data
    }

    /// Extract a user-facing error message from a server JSON error
    /// response, falling back to a generic message.
    private func extractServerError(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return json["message"] as? String
            ?? json["error"] as? String
            ?? json["detail"] as? String
    }

    /// Extract a user-facing error message from a Swift Error.
    private func extractErrorMessage(_ error: Error) -> String {
        if let zoneError = error as? ZoneAuthError {
            switch zoneError {
            case .invalidURL:
                return "Invalid server URL"
            case .invalidResponse:
                return "Invalid response from server"
            case .serverError(let detail):
                return detail
            }
        }
        return error.localizedDescription
    }

    /// Errors from zone auth HTTP requests.
    private enum ZoneAuthError: Error {
        case invalidURL
        case invalidResponse
        case serverError(String)
    }
}
