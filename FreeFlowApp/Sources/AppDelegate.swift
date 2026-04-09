import AppKit
import FreeFlowKit

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
    private var updaterService: UpdaterService?
    private let micDiagnosticStore = MicDiagnosticStore()

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?
    private var onboardingController: OnboardingController?
    private var settingsController: SettingsController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        purgeLegacyV01State()
        setupMenuBar()
        setupPipeline()
        setupUpdater()
        setupSettings()
        setupMenuBarState()
        determineLaunchFlow()
    }

    /// Clean up Keychain items and UserDefaults keys left behind by the
    /// v0.1.0 server-backed build. Runs once per install; the marker is
    /// stored in UserDefaults under `didPurgeV01State`.
    ///
    /// v0.1.0 and the current build share the same bundle identifier
    /// (`computer.autonomy.freeflow`) so Sparkle can upgrade in place.
    /// That means the current build inherits the old build's
    /// UserDefaults plist and has read access to the old Keychain
    /// items. None of those are used by the current build and some of
    /// them (session tokens, zone URLs) are security-sensitive, so we
    /// delete them on first launch after upgrading.
    private func purgeLegacyV01State() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didPurgeV01State") else { return }

        Log.debug("[AppDelegate] Purging v0.1.0 legacy state")

        keychain.purgeLegacyV01Items()

        // UserDefaults keys that were meaningful in v0.1.0 but are no
        // longer read. Settings (language, shortcut bindings, sound
        // feedback) are preserved so the user keeps their preferences.
        let legacyDefaults = [
            "hasCompletedOnboarding",
            "hasEmailOnFile",
        ]
        for key in legacyDefaults {
            defaults.removeObject(forKey: key)
        }

        defaults.set(true, forKey: "didPurgeV01State")
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

    // MARK: - Launch Flow

    /// Decide what to show on launch based on stored config.
    ///
    /// If the Keychain has an OpenAI API key, skip straight to permissions
    /// and hotkey registration. Otherwise show the onboarding window so
    /// the user can enter one.
    private func determineLaunchFlow() {
        if ServiceConfig.shared.isConfigured {
            Log.debug("[AppDelegate] API key present, checking permissions")
            checkPermissions()
        } else {
            Log.debug("[AppDelegate] No API key, showing onboarding")
            showOnboarding()
        }
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        menuBarController?.onReopenOnboarding = { [weak self] in
            self?.onboardingController?.showWindow()
        }
        menuBarController?.setOnboardingMode(true)
        let controller = ensureOnboardingController()
        controller.showWindow()
    }

    private func ensureOnboardingController() -> OnboardingController {
        if let existing = onboardingController {
            return existing
        }

        let controller = OnboardingController(keychain: keychain)

        controller.permissionProvider = permissionProvider
        controller.audioDeviceProvider = audioDeviceProvider
        controller.audioPreviewProvider = audioProvider
        controller.soundFeedbackProvider = soundFeedbackProvider

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
            var previousState: RecordingState = .idle
            for await state in await coord.stateStream {
                if Task.isCancelled { break }

                // Trigger on any exit from .injecting: the transcript
                // buffer was written before the injecting transition,
                // so it is available whether injection succeeded (.idle)
                // or failed (.injectionFailed).
                if previousState == .injecting
                    && (state == .idle || state == .injectionFailed)
                {
                    let text = await buffer.lastTranscript
                    if let text, !text.isEmpty {
                        await MainActor.run {
                            self?.onboardingController?.onDictationResult?(text)
                        }
                    }
                    // During onboarding the system injection target is
                    // the app itself, so .injectionFailed is expected.
                    // Reset to idle to dismiss the no-target HUD hint.
                    if state == .injectionFailed {
                        await coord.finishInjecting()
                    }
                }
                previousState = state
            }
        }
    }

    private func stopOnboardingDictationObserver() {
        onboardingDictationTask?.cancel()
        onboardingDictationTask = nil
    }

    // MARK: - Updater

    private func setupUpdater() {
        updaterService = UpdaterService()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "FreeFlow"
            )
        }

        self.statusItem = statusItem
    }

    // MARK: - Pipeline

    private let audioProvider = AudioCaptureProvider()

    private func setupPipeline() {
        audioProvider.setAudioDeviceProvider(audioDeviceProvider)
        audioProvider.setSoundFeedbackProvider(soundFeedbackProvider)
        audioDeviceProvider.setAudioCaptureProvider(audioProvider)

        let polishClient = OpenAIChatClient(
            apiKey: ServiceConfig.shared.openAIAPIKey ?? "")
        let streamingProvider = OpenAIRealtimeProvider(
            apiKey: ServiceConfig.shared.openAIAPIKey ?? "",
            polishChatClient: polishClient)
        let dictationProvider = OpenAIDictationProvider(
            apiKey: ServiceConfig.shared.openAIAPIKey ?? "",
            polishChatClient: polishClient)

        let newPipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            dictationProvider: dictationProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: streamingProvider,
            onSessionExpired: { [weak self] in
                Task { @MainActor in self?.resetAPIKey() }
            },
            micDiagnosticStore: micDiagnosticStore
        )
        pipeline = newPipeline

        // Apply the persisted language setting.
        Task {
            await newPipeline.setLanguage(LanguageSetting.current.languageCode)
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
        controller.onSessionExpired = { [weak self] in
            self?.resetAPIKey()
        }
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
            micDiagnosticStore: micDiagnosticStore,
            shortcuts: .default
        )
        menuBarController = controller

        controller.onOpenSettings = { [weak self] in
            self?.showSettings()
        }

        controller.onResetAPIKey = { [weak self] in
            self?.resetAPIKey()
        }
    }

    /// Clear the stored API key and return to onboarding.
    private func resetAPIKey() {
        Log.debug("[AppDelegate] Reset API key requested")

        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)
        hudController?.stop()
        hudController = nil

        Task { await coordinator.reset() }

        keychain.deleteOpenAIAPIKey()
        showOnboarding()
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

        // Create the HUD on first hotkey registration.
        if hudController == nil {
            setupHUD()
        }

        let pipelineRef = pipeline
        let hudRef = hudController
        let menuRef = menuBarController

        do {
            try hotkeyProvider.register { event in
                Task { @MainActor in
                    switch event {
                    case .pressed:
                        hudRef?.hotkeyHeld()
                        Task {
                            await pipelineRef.activate()
                        }
                    case .released:
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
            FreeFlow could not register the global hotkey (Right Option). \
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
