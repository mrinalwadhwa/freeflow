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
    private let authClient = AuthClient()
    private let capabilitiesService = CapabilitiesService()
    private var updaterService: UpdaterService?
    private let trialStatusService = TrialStatusService()
    private let micDiagnosticStore = MicDiagnosticStore()

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?
    private var onboardingController: OnboardingController?
    private var settingsController: SettingsController?
    private var peopleController: PeopleController?
    private var billingController: BillingController?
    private var provisioningController: ProvisioningController?
    private var trialExpiredWindow: TrialExpiredWindow?
    private var trialObservationTask: Task<Void, Never>?

    /// URLs received before applicationDidFinishLaunching completes.
    private var pendingURLs: [URL] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPipeline()
        setupUpdater()
        setupSettings()
        setupPeople()
        setupMenuBarState()

        // Process any freeflow:// URLs received before launch finished.
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
        trialStatusService.stopPolling()
        trialObservationTask?.cancel()
        trialObservationTask = nil
        trialExpiredWindow?.dismiss()
        provisioningController?.dismissWindow()
        onboardingController?.dismissWindow()
        settingsController?.closeWindow()
        peopleController?.closeWindow()
        billingController?.dismissWindow()
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
        guard url.scheme == "freeflow" else { return }

        Log.debug("[AppDelegate] Received URL: \(url)")

        // freeflow://auth/ready is handled by ASWebAuthenticationSession's
        // completion handler in AuthController. It does not reach here.
        // Route freeflow://connect to the existing invite flow.
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host == "connect"
        {
            provisioningController?.dismissWindow()
            provisioningController = nil
            let controller = ensureOnboardingController()
            controller.handleConnectURL(url)
        }
    }

    // MARK: - Launch Flow

    /// Decide what to show on launch based on stored config.
    ///
    /// Decision tree:
    /// 1. If onboarding completed and Keychain has a session token: validate
    ///    session, then check permissions and register hotkey.
    /// 2. If a zone URL exists but onboarding is incomplete: resume onboarding.
    /// 3. If an Autonomy token exists but no zone URL: resume provisioning.
    /// 4. Otherwise: show onboarding and wait for an invite link.
    private func determineLaunchFlow() {
        let config = ServiceConfig.shared

        // Onboarded: validate the session.
        if config.isOnboarded && UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            Log.debug("[AppDelegate] Onboarded, validating session")
            validateSessionAndLaunch()
            return
        }

        // Has a zone URL but onboarding not completed: resume onboarding
        // (e.g. app quit after provisioning but before finishing setup).
        if config.isOnboarded {
            Log.debug("[AppDelegate] Has zone URL, resuming onboarding")
            showOnboarding()
            return
        }

        // Has an Autonomy token but no zone URL: provisioning was
        // interrupted. Resume polling.
        if keychain.autonomyToken() != nil && keychain.serviceURL() == nil {
            Log.debug("[AppDelegate] Resuming interrupted provisioning")
            showProvisioningFlow(resume: true)
            return
        }

        // No stored zone URL and no provisioning state: wait for an invite
        // link instead of forcing provisioning. This supports invited users
        // and local disconnect/reset without deleting server-side identity.
        Log.debug("[AppDelegate] No zone URL, showing onboarding waiting state")
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
                    && !session.email.hasSuffix("@placeholder.freeflow.local")
                if hasRealEmail {
                    UserDefaults.standard.set(true, forKey: "hasEmailOnFile")
                    keychain.saveUserEmail(session.email)
                }

                // Show the signed-in email in the menu bar. Prefer the
                // Autonomy Account email (the one used to sign up) over
                // the zone email (which may be a placeholder).
                updateMenuBarEmail()

                // Proceed to permissions and hotkey.
                checkPermissions()

                // Check capabilities in the background, then start the
                // updater once the appcast URL is cached.
                checkCapabilitiesInBackground()

                // Start trial status monitoring for admin users.
                startTrialMonitoring()

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
        let email = keychain.userEmail()

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

    private func showOnboarding(
        skipConnect: Bool = false, addedCard: Bool = false, windowFrame: NSRect? = nil
    ) {
        menuBarController?.onReopenOnboarding = { [weak self] in
            self?.onboardingController?.showWindow(path: "/onboarding/")
        }
        menuBarController?.setOnboardingMode(true)
        let controller = ensureOnboardingController()
        var path = skipConnect ? "/onboarding/?skip=connect" : "/onboarding/"
        if addedCard {
            path += path.contains("?") ? "&addedCard=true" : "?addedCard=true"
        }
        controller.showWindow(path: path)
        // If transitioning from provisioning, place the onboarding
        // window where the provisioning window was so it doesn't jump.
        if let frame = windowFrame {
            controller.window?.setFrameOrigin(frame.origin)
        }
    }

    private func startProvisioningFromOnboarding() {
        let windowFrame = onboardingController?.window?.frame
        onboardingController?.dismissWindow()
        onboardingController = nil
        showProvisioningFlow(windowFrame: windowFrame)
    }

    // MARK: - Provisioning Flow

    /// Show the provisioning flow for fresh installs.
    ///
    /// Creates a ProvisioningController that handles Autonomy Account login, zone
    /// provisioning, and the handoff to the existing onboarding flow
    /// (accessibility → mic → try-it → done).
    ///
    /// - Parameter resume: If true, attempt to resume an interrupted
    ///   provisioning session using a stored Autonomy token.
    private func showProvisioningFlow(resume: Bool = false, windowFrame: NSRect? = nil) {
        let controller = ProvisioningController(
            keychain: keychain,
            authClient: authClient
        )

        controller.onComplete = { [weak self] zoneUrl, _ in
            guard let self else { return }
            Log.debug("[AppDelegate] Provisioning complete, transitioning to onboarding")
            self.updateMenuBarEmail()
            // Capture the window position before dismissing so the
            // onboarding window can appear in the same spot.
            let windowFrame = self.provisioningController?.window?.frame
            let addedCard = self.provisioningController?.addedCard ?? false
            self.provisioningController?.dismissWindow()
            self.provisioningController = nil
            self.showOnboarding(skipConnect: true, addedCard: addedCard, windowFrame: windowFrame)
        }

        controller.onError = { error in
            Log.debug("[AppDelegate] Provisioning error: \(error.localizedDescription)")
            // The provisioning UI shows the error with a retry button.
        }

        provisioningController = controller
        controller.showWindow()

        if let frame = windowFrame {
            controller.window?.setFrameOrigin(frame.origin)
        }

        if resume {
            controller.resumeIfNeeded()
        }
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
        controller.soundFeedbackProvider = soundFeedbackProvider

        controller.onRegisterHotkey = { [weak self] in
            self?.registerHotkey()
            self?.startOnboardingDictationObserver()
        }

        controller.onStartAdminSetup = { [weak self] in
            self?.startProvisioningFromOnboarding()
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
            #if DEBUG
                Log.debug("[OnboardingObserver] Started")
            #endif
            var previousState: RecordingState = .idle
            for await state in await coord.stateStream {
                if Task.isCancelled { break }

                #if DEBUG
                    Log.debug("[OnboardingObserver] State: \(previousState) → \(state)")
                #endif

                // Trigger on any exit from .injecting: the transcript
                // buffer was written before the injecting transition,
                // so it is available whether injection succeeded (.idle)
                // or failed (.injectionFailed).
                if previousState == .injecting
                    && (state == .idle || state == .injectionFailed)
                {
                    let text = await buffer.lastTranscript
                    #if DEBUG
                        Log.debug("[OnboardingObserver] Buffer text: \(text ?? "<nil>")")
                    #endif
                    if let text, !text.isEmpty {
                        let hasCallback = await MainActor.run {
                            self?.onboardingController?.onDictationResult != nil
                        }
                        #if DEBUG
                            Log.debug(
                                "[OnboardingObserver] onDictationResult callback present: \(hasCallback)"
                            )
                        #endif
                        await MainActor.run {
                            self?.onboardingController?.onDictationResult?(text)
                        }
                        #if DEBUG
                            Log.debug("[OnboardingObserver] Pushed dictation result to bridge")
                        #endif
                    }
                    // During onboarding the system injection target is
                    // the app itself, so .injectionFailed is expected.
                    // Reset to idle to dismiss the no-target HUD hint.
                    if state == .injectionFailed {
                        #if DEBUG
                            Log.debug("[OnboardingObserver] Resetting injectionFailed → idle")
                        #endif
                        await coord.finishInjecting()
                    }
                }
                previousState = state
            }
            #if DEBUG
                Log.debug("[OnboardingObserver] Stopped")
            #endif
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
        let newPipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            dictationProvider: FreeFlowServiceDictationProvider(),
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: FreeFlowServiceStreamingProvider(),
            onSessionExpired: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleInlineSessionExpired()
                }
            },
            micDiagnosticStore: micDiagnosticStore
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
            micDiagnosticStore: micDiagnosticStore,
            shortcuts: .default
        )
        menuBarController = controller

        // Wire settings action.
        controller.onOpenSettings = { [weak self] in
            self?.showSettings()
        }

        // Wire people action.
        controller.onOpenPeople = { [weak self] in
            self?.showPeople()
        }

        // Wire sign-out action.
        controller.onSignOut = { [weak self] in
            self?.signOut()
        }

        // Wire disconnect action (for invited users).
        controller.onDisconnect = { [weak self] in
            self?.disconnectFromCurrentServer()
        }

        // Wire "Add credit card…" from the trial status menu item.
        controller.onAddCreditCard = { [weak self] in
            self?.showBillingForTrial()
        }

        // Set admin/invitee role based on whether an Autonomy token
        // exists. Admins provisioned the server and signed in via
        // Auth0; invitees redeemed an invite link and have no
        // Autonomy token.
        controller.setIsAdmin(keychain.autonomyToken() != nil)
    }

    /// Update the menu bar with the best available email for the
    /// signed-in user. Prefers the Autonomy Account email (Auth0)
    /// over the zone user email.
    private func updateMenuBarEmail() {
        #if DEBUG
            if let envEmail = ProcessInfo.processInfo.environment["FREEFLOW_AUTONOMY_EMAIL"],
                !envEmail.isEmpty
            {
                menuBarController?.setSignedInEmail(envEmail)
                menuBarController?.setIsAdmin(keychain.autonomyToken() != nil)
                return
            }
        #endif
        let email = keychain.autonomyEmail() ?? keychain.userEmail()
        menuBarController?.setSignedInEmail(email)
        menuBarController?.setIsAdmin(keychain.autonomyToken() != nil)
    }

    /// Sign out: clear all stored credentials and return to the
    /// provisioning flow so the user can sign in with a different
    /// account.
    private func signOut() {
        Log.debug("[AppDelegate] Sign out requested")

        // Stop the hotkey and HUD.
        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)
        hudController?.stop()
        hudController = nil

        // Stop trial monitoring.
        trialStatusService.stopPolling()
        trialObservationTask?.cancel()
        trialObservationTask = nil
        trialExpiredWindow?.dismiss()
        trialExpiredWindow = nil

        // Reset the coordinator so stale pipeline state is cleared.
        Task { await coordinator.reset() }

        // Dismiss any open windows.
        onboardingController?.dismissWindow()
        onboardingController = nil
        settingsController?.closeWindow()
        peopleController?.closeWindow()
        billingController?.dismissWindow()
        billingController = nil

        // Clear all stored credentials and state.
        keychain.deleteAll()
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "hasEmailOnFile")

        // Clear the menu bar email and trial state.
        menuBarController?.setSignedInEmail(nil)
        menuBarController?.setTrialState(nil)

        // Return to the provisioning flow.
        showProvisioningFlow()
    }

    /// Disconnect from the currently connected FreeFlow server without
    /// deleting any server-side identity. This is intended for invited
    /// users who want to reset their local app connection and later
    /// reconnect with a fresh invite or recovery flow.
    private func disconnectFromCurrentServer() {
        Log.debug("[AppDelegate] Disconnect from current server requested")

        // Stop the hotkey and HUD.
        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)
        hudController?.stop()
        hudController = nil

        // Reset the coordinator so stale pipeline state is cleared.
        Task { await coordinator.reset() }

        // Dismiss any open windows tied to the current session.
        onboardingController?.dismissWindow()
        onboardingController = nil
        settingsController?.closeWindow()
        peopleController?.closeWindow()
        billingController?.dismissWindow()
        billingController = nil

        // Clear only local zone/session state. Keep Autonomy credentials
        // intact so admin sign-in remains distinct from invitee disconnect.
        keychain.deleteSessionToken()
        keychain.deleteServiceURL()
        keychain.deleteUserEmail()
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.removeObject(forKey: "hasEmailOnFile")

        // Clear the displayed email because there is no active zone session.
        menuBarController?.setSignedInEmail(nil)

        // Return to onboarding waiting state and wait for the next invite
        // link or recovery action.
        showOnboarding()
    }

    // MARK: - People

    private func setupPeople() {
        let controller = PeopleController()
        controller.onOpenBilling = { [weak self] in
            self?.showBilling()
        }
        controller.onDisconnectFromServer = { [weak self] in
            self?.disconnectFromCurrentServer()
        }
        peopleController = controller
    }

    // MARK: - Billing

    /// Show the billing window for adding a credit card.
    ///
    /// Called from the People page when the user taps "Add credit card"
    /// in the locked state.
    private func showBilling() {
        if billingController == nil {
            let controller = BillingController()
            controller.onComplete = { [weak self] in
                Log.debug("[AppDelegate] Billing complete, refreshing People page")
                // Close billing window
                self?.billingController?.dismissWindow()
                self?.billingController = nil
                // Refresh trial state immediately.
                self?.refreshTrialState()
                // Re-show People page so it reloads with updated state
                self?.peopleController?.showWindow()
            }
            controller.onCancel = { [weak self] in
                self?.billingController = nil
            }
            billingController = controller
        }
        billingController?.showWindow()
    }

    /// Show the billing window for adding a credit card from the trial
    /// status menu item or the trial expired modal.
    ///
    /// On success, refreshes trial state and, if the trial had expired,
    /// re-provisions the zone to restore service.
    private func showBillingForTrial() {
        let wasExpired = trialStatusService.current?.isExpired ?? false

        if billingController == nil {
            let controller = BillingController()
            controller.onComplete = { [weak self] in
                guard let self else { return }
                Log.debug("[AppDelegate] Billing (trial) complete")
                self.billingController?.dismissWindow()
                self.billingController = nil
                self.trialExpiredWindow?.dismiss()
                self.trialExpiredWindow = nil

                if wasExpired {
                    // Zone was deleted on trial expiry. Re-provision it.
                    self.reProvisionAfterTrialRecovery()
                } else {
                    // Still in trial, card added. Just refresh state.
                    self.refreshTrialState()
                }
            }
            controller.onCancel = { [weak self] in
                self?.billingController = nil
            }
            billingController = controller
        }
        billingController?.showWindow()
    }

    // MARK: - Trial Monitoring

    /// Start observing trial status from the Autonomy orchestrator.
    ///
    /// Only meaningful for admin users (those with an Autonomy token).
    /// Does an immediate check, then polls on a schedule. Updates the
    /// menu bar trial indicator and handles trial expiry.
    private func startTrialMonitoring() {
        // Only admins have trial state. Guests have no Autonomy token.
        guard keychain.autonomyToken() != nil else { return }

        trialObservationTask?.cancel()
        trialObservationTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.trialStatusService.stateStream {
                guard !Task.isCancelled else { break }
                self.menuBarController?.setTrialState(state)

                if state.isExpired {
                    self.handleTrialExpired()
                }
            }
        }

        trialStatusService.startPolling()
    }

    /// Refresh trial state immediately (e.g. after adding a card).
    private func refreshTrialState() {
        Task {
            let state = await trialStatusService.checkNow()
            menuBarController?.setTrialState(state)
        }
    }

    /// Handle trial expiry: disable dictation and show the expired modal.
    private func handleTrialExpired() {
        Log.debug("[AppDelegate] Trial expired, disabling dictation")

        // Disable dictation so the user doesn't get confusing errors.
        hotkeyProvider.unregister()
        menuBarController?.setHotkeyRegistered(false)

        // Show the trial expired modal if not already showing.
        guard trialExpiredWindow == nil else { return }

        let window = TrialExpiredWindow()
        window.onAddCard = { [weak self] in
            self?.showBillingForTrial()
        }
        window.onDismiss = { [weak self] in
            self?.trialExpiredWindow?.dismiss()
            self?.trialExpiredWindow = nil
        }
        trialExpiredWindow = window
        window.present()
    }

    /// Re-provision the zone after the user adds a card to recover from
    /// trial expiry.
    ///
    /// The orchestrator's `card_configured` has already moved the user
    /// from `trial_expired` to `active`. Now we need to re-create the
    /// zone (it was deleted on expiry) and restore service.
    private func reProvisionAfterTrialRecovery() {
        Log.debug("[AppDelegate] Re-provisioning zone after trial recovery")

        guard let token = keychain.autonomyToken() else {
            Log.debug("[AppDelegate] No Autonomy token for re-provisioning")
            return
        }

        // Show a simple provisioning flow. Reuse the provisioning
        // controller which handles the full provision → poll → redeem
        // → ready cycle.
        let controller = ProvisioningController(
            keychain: keychain,
            authClient: authClient
        )

        controller.onComplete = { [weak self] zoneUrl, _ in
            guard let self else { return }
            Log.debug("[AppDelegate] Re-provisioning complete, resuming")
            self.provisioningController?.dismissWindow()
            self.provisioningController = nil
            self.updateMenuBarEmail()
            self.refreshTrialState()

            // Re-register the hotkey so dictation works again.
            self.checkPermissions()
        }

        controller.onError = { error in
            Log.debug("[AppDelegate] Re-provisioning failed: \(error.localizedDescription)")
        }

        provisioningController = controller

        // Instead of showing the full provisioning window with Get Started,
        // directly trigger re-provisioning using the existing token.
        controller.showWindow()
        // The provisioning window will show the spinner. The controller's
        // resumeIfNeeded won't work here because we DO have a serviceURL
        // (stale). Clear it so the resume path kicks in, or call start
        // which will use the existing Autonomy token.
        //
        // Actually, the zone was deleted so we need a fresh provision.
        // Clear the stale zone URL so resumeIfNeeded triggers correctly.
        keychain.deleteServiceURL()
        keychain.deleteSessionToken()
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        controller.resumeIfNeeded()
    }

    /// Show the People window.
    private func showPeople() {
        peopleController?.showWindow()
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

        // Create the HUD on first hotkey registration (try-it step
        // during onboarding, or permissions-granted on returning users).
        if hudController == nil {
            setupHUD()
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

// MARK: - AuthError convenience

extension AuthClient.AuthError {
    /// Whether this error indicates the session token is no longer valid.
    var isSessionExpired: Bool {
        if case .sessionExpired = self { return true }
        return false
    }
}
