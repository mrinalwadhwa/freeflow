import AVFoundation
import AppKit
import VoiceKit

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
    private var window: OnboardingWindow?

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

    /// Polling timer for accessibility permission checks.
    private var accessibilityPollTimer: Timer?

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
    /// without recreating it.
    ///
    /// - Parameter path: The path to load, e.g. `/onboarding/?token=abc`.
    func showWindow(path: String) {
        if window == nil {
            let win = OnboardingWindow(bridge: bridge)
            bridge.webView = win.webView
            window = win
        }

        let baseURL = config.baseURL
        window?.navigate(baseURL: baseURL, path: path)
        window?.present()
    }

    /// Open the onboarding flow for a voice:// connect URL.
    ///
    /// Parses the URL, stores the service URL in the Keychain, and
    /// opens the onboarding page with the invite token.
    func handleConnectURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "voice",
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

        bridge.onRegisterHotkey = { [weak self] in
            self?.handleRegisterHotkey()
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
        UserDefaults.standard.set(email, forKey: "userEmail")
    }

    // MARK: - Action: checkAccessibility

    private func handleCheckAccessibility() {
        let granted = permissionProvider?.checkAccessibility() == .granted
        let micGranted = UserDefaults.standard.bool(forKey: "microphoneGranted")

        bridge.pushPermissionStatus(
            accessibility: granted ? "granted" : "denied",
            microphone: micGranted ? "granted" : "unknown"
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
        let micGranted = UserDefaults.standard.bool(forKey: "microphoneGranted")

        bridge.pushPermissionStatus(
            accessibility: granted ? "granted" : "denied",
            microphone: micGranted ? "granted" : "unknown"
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
