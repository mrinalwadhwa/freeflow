import AppKit
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
    private let soundFeedbackProvider = SoundFeedbackProvider()
    private var pipeline: DictationPipeline?

    private let keychain = KeychainService()
    private let authClient = AuthClient()
    private let capabilitiesService = CapabilitiesService()
    private var updaterService: UpdaterService?

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?
    private var onboardingController: OnboardingController?
    private var settingsController: SettingsController?

    /// URLs received before applicationDidFinishLaunching completes.
    private var pendingURLs: [URL] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPipeline()
        setupHUD()
        setupUpdater()
        setupSettings()
        setupMenuBarState()

        // Process any voice:// URLs received before launch finished.
        if let url = pendingURLs.first {
            pendingURLs.removeAll()
            handleIncomingURL(url)
        } else {
            determineLaunchFlow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyProvider.unregister()
        hudController?.stop()
        menuBarController?.stop()
        permissionController?.stop()
        audioProvider.shutdown()
        soundFeedbackProvider.shutdown()
        onboardingController?.dismissWindow()
        settingsController?.closeWindow()
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

                // Check capabilities in the background, then start the
                // updater once the appcast URL is cached.
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
                checkCapabilitiesInBackground(startUpdater: true)
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

    private func checkCapabilitiesInBackground(startUpdater: Bool = true) {
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

                // Start the updater now that the appcast URL is cached.
                if startUpdater {
                    updaterService?.startIfNeeded()
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
        menuBarController?.onReopenOnboarding = { [weak self] in
            self?.onboardingController?.showWindow(path: "/onboarding/")
        }
        menuBarController?.setOnboardingMode(true)
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
        controller.audioDeviceProvider = audioDeviceProvider
        controller.audioPreviewProvider = audioProvider

        controller.onRegisterHotkey = { [weak self] in
            self?.registerHotkey()
            self?.startOnboardingDictationObserver()
        }

        controller.onComplete = { [weak self] in
            guard let self else { return }
            Log.debug("[AppDelegate] Onboarding complete")
            self.stopOnboardingDictationObserver()
            self.onboardingController = nil
            self.menuBarController?.setOnboardingMode(false)
            self.menuBarController?.onReopenOnboarding = nil
            self.checkPermissions()
            self.checkCapabilitiesInBackground()
        }

        onboardingController = controller
        return controller
    }

    // MARK: - Onboarding dictation observer

    /// Observe coordinator state changes during onboarding to push
    /// dictation results to the try-it screen via the bridge.
    ///
    /// Uses `stateStream` instead of polling so no transitions are missed.
    /// The transcript buffer is populated before injection starts, so
    /// reading it on any exit from `.injecting` (success or failure)
    /// reliably captures the result.
    private var onboardingDictationTask: Task<Void, Never>?

    private func startOnboardingDictationObserver() {
        stopOnboardingDictationObserver()
        let coord = coordinator
        let buffer = transcriptBuffer
        onboardingDictationTask = Task { [weak self] in
            Log.debug("[OnboardingObserver] Started")
            var previousState: RecordingState = .idle
            for await state in await coord.stateStream {
                if Task.isCancelled { break }

                Log.debug("[OnboardingObserver] State: \(previousState) → \(state)")

                // Trigger on any exit from .injecting: the transcript
                // buffer was written before the injecting transition,
                // so it is available whether injection succeeded (.idle)
                // or failed (.injectionFailed).
                if previousState == .injecting
                    && (state == .idle || state == .injectionFailed)
                {
                    let text = await buffer.lastTranscript
                    Log.debug("[OnboardingObserver] Buffer text: \(text ?? "<nil>")")
                    if let text, !text.isEmpty {
                        let hasCallback = await MainActor.run {
                            self?.onboardingController?.onDictationResult != nil
                        }
                        Log.debug(
                            "[OnboardingObserver] onDictationResult callback present: \(hasCallback)"
                        )
                        await MainActor.run {
                            self?.onboardingController?.onDictationResult?(text)
                        }
                        Log.debug("[OnboardingObserver] Pushed dictation result to bridge")
                    }
                    // During onboarding the system injection target is
                    // the app itself, so .injectionFailed is expected.
                    // Reset to idle to dismiss the no-target HUD hint.
                    if state == .injectionFailed {
                        Log.debug("[OnboardingObserver] Resetting injectionFailed → idle")
                        await coord.finishInjecting()
                    }
                }
                previousState = state
            }
            Log.debug("[OnboardingObserver] Stopped")
        }
    }

    private func stopOnboardingDictationObserver() {
        onboardingDictationTask?.cancel()
        onboardingDictationTask = nil
    }

    // MARK: - Updater

    private func setupUpdater() {
        let service = UpdaterService(capabilitiesService: capabilitiesService)
        updaterService = service
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
        audioProvider.setSoundFeedbackProvider(soundFeedbackProvider)
        let newPipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            dictationProvider: VoiceServiceDictationProvider(),
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: VoiceServiceStreamingProvider(),
            onSessionExpired: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleInlineSessionExpired()
                }
            }
        )
        pipeline = newPipeline

        // Apply the persisted language setting.
        Task {
            await newPipeline.setLanguage(LanguageSetting.current.languageCode)
        }
    }

    /// Handle a 401 auth error from a dictation request mid-session.
    ///
    /// Clear the stored session token so subsequent requests do not keep
    /// failing, then enter the recovery flow (sign-in if the user has an
    /// email on file, onboarding otherwise). The coordinator is already
    /// in `.sessionExpired` state (set by the pipeline), so the HUD shows
    /// a brief "Session expired" message while recovery opens.
    private func handleInlineSessionExpired() {
        Log.debug("[AppDelegate] Inline 401: clearing Keychain, entering recovery")
        keychain.deleteSessionToken()
        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)

        // Brief delay so the user sees the "Session expired" HUD message
        // before the recovery window appears.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self else { return }
            await self.coordinator.reset()
            self.handleSessionExpired()
        }
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
            pipeline: pipeline,
            transcriptBuffer: transcriptBuffer,
            textInjector: textInjector,
            audioDeviceProvider: audioDeviceProvider,
            updaterService: updaterService,
            shortcuts: .default
        )
        menuBarController = controller

        // Wire settings action.
        controller.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
    }

    // MARK: - Settings

    private func setupSettings() {
        let controller = SettingsController()
        controller.audioDeviceProvider = audioDeviceProvider
        controller.audioPreviewProvider = audioProvider
        controller.soundFeedbackProvider = soundFeedbackProvider
        controller.pipeline = pipeline
        controller.onHotkeyChanged = { [weak self] in
            self?.reRegisterHotkey()
        }
        settingsController = controller
    }

    /// Show the settings window.
    private func showSettings() {
        settingsController?.showWindow()
    }

    /// Re-register the hotkey after settings change.
    private func reRegisterHotkey() {
        hotkeyProvider.unregister()
        registerHotkey()
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
