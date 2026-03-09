import AppKit
import SwiftUI
import VoiceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    // MARK: - Services

    private let coordinator = RecordingCoordinator()
    private let permissionProvider = MicrophonePermissionProvider()
    private let hotkeyProvider = CGEventTapHotkeyProvider()
    private let transcriptBuffer = TranscriptBuffer()
    private let textInjector = AppTextInjector()
    private let audioDeviceProvider = CoreAudioDeviceProvider()
    private var pipeline: DictationPipeline?

    private let keychain = KeychainService()
    private let authClient = AuthClient()
    private let capabilitiesService = CapabilitiesService()

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?
    private var onboardingController: OnboardingController?

    /// URLs received before applicationDidFinishLaunching completes.
    private var pendingURLs: [URL] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPipeline()
        setupHUD()
        setupMenuBarState()

        // Process any voice:// URLs received before launch finished.
        if let url = pendingURLs.first {
            pendingURLs.removeAll()
            handleIncomingURL(url)
        } else {
            determineLaunchFlow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyProvider.unregister()
        hudController?.stop()
        menuBarController?.stop()
        permissionController?.stop()
        audioProvider.shutdown()
        onboardingController?.dismissWindow()
    }

    // MARK: - URL Scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }

        // If the app hasn't finished launching yet, queue the URL.
        if pipeline == nil {
            pendingURLs.append(url)
            return
        }

        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme == "voice" else { return }

        Log.debug("[AppDelegate] Received URL: \(url)")
        let controller = ensureOnboardingController()
        controller.handleConnectURL(url)
    }

    // MARK: - Launch Flow

    /// Decide what to show on launch based on stored config.
    ///
    /// Decision tree:
    /// 1. If env vars are set and no Keychain data: dev mode, skip onboarding.
    /// 2. If onboarding completed and Keychain has a session token: validate
    ///    session, then check permissions and register hotkey.
    /// 3. Otherwise: show onboarding window.
    private func determineLaunchFlow() {
        let config = ServiceConfig.shared

        // Dev mode: env vars set, no Keychain token. Preserve existing
        // behavior for development without onboarding.
        if !config.isOnboarded && !config.apiKey.isEmpty {
            Log.debug("[AppDelegate] Dev mode (env vars), skipping onboarding")
            checkPermissions()
            return
        }

        // Onboarded: validate the session.
        if config.isOnboarded && UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            Log.debug("[AppDelegate] Onboarded, validating session")
            validateSessionAndLaunch()
            return
        }

        // Not onboarded: show the onboarding window.
        Log.debug("[AppDelegate] Not onboarded, showing onboarding window")
        showOnboarding()
    }

    // MARK: - Session Validation

    private func validateSessionAndLaunch() {
        let config = ServiceConfig.shared

        guard let token = config.sessionToken else {
            Log.debug("[AppDelegate] No session token, showing onboarding")
            showOnboarding()
            return
        }

        Task {
            do {
                let session = try await authClient.validateSession(
                    serviceURL: config.baseURL,
                    token: token
                )
                Log.debug("[AppDelegate] Session valid for user \(session.userId)")

                // Track email status from the session.
                let hasRealEmail =
                    session.emailVerified
                    && !session.email.hasSuffix("@placeholder.voice.local")
                if hasRealEmail {
                    UserDefaults.standard.set(true, forKey: "hasEmailOnFile")
                    UserDefaults.standard.set(session.email, forKey: "userEmail")
                }

                // Proceed to permissions and hotkey.
                checkPermissions()

                // Check capabilities in the background.
                checkCapabilitiesInBackground()

            } catch let error as AuthClient.AuthError where error.isSessionExpired {
                Log.debug("[AppDelegate] Session expired, entering recovery flow")
                handleSessionExpired()

            } catch {
                // Network error: proceed optimistically. The server will
                // reject individual requests if the session is actually
                // invalid, and inline 401 handling will trigger recovery.
                Log.debug(
                    "[AppDelegate] Session validation failed (network?): \(error), proceeding optimistically"
                )
                checkPermissions()
                checkCapabilitiesInBackground()
            }
        }
    }

    private func handleSessionExpired() {
        keychain.deleteSessionToken()

        let hasEmail = UserDefaults.standard.bool(forKey: "hasEmailOnFile")
        let email = UserDefaults.standard.string(forKey: "userEmail")

        if hasEmail, let email, !email.isEmpty {
            // User has email: show sign-in page for OTP recovery.
            let controller = ensureOnboardingController()
            controller.showSignIn(email: email)
        } else {
            // No email: show onboarding welcome (ask admin for new invite).
            showOnboarding()
        }
    }

    // MARK: - Capabilities

    private func checkCapabilitiesInBackground() {
        let config = ServiceConfig.shared

        Task {
            do {
                let caps = try await capabilitiesService.check(serviceURL: config.baseURL)
                Log.debug(
                    "[AppDelegate] Capabilities: email_otp=\(caps.emailOtp), require_email=\(caps.requireEmail)"
                )

                // If email is required and user doesn't have one, prompt.
                if caps.emailOtp && !UserDefaults.standard.bool(forKey: "hasEmailOnFile") {
                    evaluateEmailPrompt(capabilities: caps)
                }
            } catch {
                Log.debug("[AppDelegate] Capabilities check failed: \(error)")
            }
        }
    }

    private func evaluateEmailPrompt(capabilities: CapabilitiesService.Capabilities) {
        switch capabilities.emailEnforcement {
        case .none:
            // Voluntary: could show a subtle prompt, but not blocking.
            break

        case .gracePeriod:
            // Grace period: show add-email on launch, dismissable.
            let controller = ensureOnboardingController()
            controller.showAddEmail(variant: "grace")

        case .enforced:
            // Enforced: show add-email, blocks dictation.
            hotkeyProvider.unregister()
            menuBarController?.setHotkeyRegistered(false)
            let controller = ensureOnboardingController()
            controller.showAddEmail(variant: "enforced")
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let controller = ensureOnboardingController()
        controller.showWindow(path: "/onboarding/")
    }

    private func ensureOnboardingController() -> OnboardingController {
        if let existing = onboardingController {
            return existing
        }

        let controller = OnboardingController(
            keychain: keychain,
            authClient: authClient,
            capabilitiesService: capabilitiesService,
            config: .shared
        )

        controller.permissionProvider = permissionProvider

        controller.onRegisterHotkey = { [weak self] in
            self?.registerHotkey()
        }

        controller.onComplete = { [weak self] in
            guard let self else { return }
            Log.debug("[AppDelegate] Onboarding complete")
            self.onboardingController = nil
            self.checkPermissions()
            self.checkCapabilitiesInBackground()
        }

        onboardingController = controller
        return controller
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Voice"
            )
        }

        self.statusItem = statusItem
    }

    // MARK: - Pipeline

    private let audioProvider = AudioCaptureProvider()

    private func setupPipeline() {
        audioProvider.setAudioDeviceProvider(audioDeviceProvider)
        pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            dictationProvider: VoiceServiceDictationProvider(),
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: VoiceServiceStreamingProvider()
        )
    }

    // MARK: - HUD

    private func setupHUD() {
        let controller = HUDController()
        controller.start(
            coordinator: coordinator,
            pipeline: pipeline,
            audioProvider: audioProvider,
            transcriptBuffer: transcriptBuffer,
            textInjector: textInjector
        )
        hudController = controller
    }

    // MARK: - Menu Bar State

    private func setupMenuBarState() {
        guard let statusItem else { return }
        let controller = MenuBarController()
        controller.start(
            statusItem: statusItem,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            textInjector: textInjector,
            audioDeviceProvider: audioDeviceProvider,
            shortcuts: .default
        )
        menuBarController = controller
    }

    // MARK: - Permissions

    private func checkPermissions() {
        let controller = PermissionController(permissionProvider: permissionProvider)
        controller.onPermissionsGranted = { [weak self] in
            self?.registerHotkey()
        }
        permissionController = controller
        controller.checkPermissions()
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        guard let pipeline else {
            Log.debug("[AppDelegate] Pipeline not initialized, cannot register hotkey")
            return
        }

        let pipelineRef = pipeline
        let hudRef = hudController
        let menuRef = menuBarController

        do {
            try hotkeyProvider.register { event in
                let t0 = CFAbsoluteTimeGetCurrent()
                Log.debug("[Hotkey] Event received: \(event) at \(t0)")
                Task { @MainActor in
                    let t1 = CFAbsoluteTimeGetCurrent()
                    Log.debug(
                        "[Hotkey] MainActor dispatch took \(String(format: "%.3f", t1 - t0))s")
                    switch event {
                    case .pressed:
                        Log.debug("[Hotkey] Pressed — calling hotkeyHeld()")
                        hudRef?.hotkeyHeld()
                        let t2 = CFAbsoluteTimeGetCurrent()
                        Log.debug(
                            "[Hotkey] hotkeyHeld() took \(String(format: "%.3f", t2 - t1))s, starting activate()"
                        )
                        Task {
                            let t3 = CFAbsoluteTimeGetCurrent()
                            await pipelineRef.activate()
                            let t4 = CFAbsoluteTimeGetCurrent()
                            Log.debug(
                                "[Hotkey] activate() took \(String(format: "%.3f", t4 - t3))s")
                        }
                    case .released:
                        Log.debug("[Hotkey] Released — completing pipeline")
                        Task { await pipelineRef.complete() }
                    }
                }
            }
            menuRef?.setHotkeyRegistered(true)
            Log.debug("[AppDelegate] Global hotkey registered (Right Option)")
        } catch {
            Log.debug("[AppDelegate] Failed to register hotkey: \(error)")
            menuRef?.setHotkeyRegistered(false)
            Task { @MainActor in
                self.showHotkeyRegistrationFailedAlert(error: error)
            }
        }
    }

    // MARK: - Alerts

    @MainActor
    private func showHotkeyRegistrationFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hotkey Registration Failed"
        alert.informativeText = """
            Voice could not register the global hotkey (Right Option). \
            \(error). \
            Try granting accessibility access and restarting the app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionProvider.openAccessibilitySettings()
        }
    }
}

// MARK: - AuthError convenience

extension AuthClient.AuthError {
    /// Whether this error indicates the session token is no longer valid.
    var isSessionExpired: Bool {
        if case .sessionExpired = self { return true }
        return false
    }
}
