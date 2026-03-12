import AppKit
import FreeFlowKit

/// Coordinate the full provisioning flow for new users.
///
/// Manages the sequence: Autonomy Account login → trigger provisioning → poll
/// until the zone is ready → redeem admin token on the zone → hand
/// off to the existing onboarding flow (accessibility → mic → try-it).
///
/// The controller owns the provisioning window and bridge. It loads
/// a bundled HTML page for the provisioning UI and communicates with
/// it via `ProvisioningBridge`.
///
/// Session 34: provisioning and billing now run in parallel. After
/// auth, the controller fires zone provisioning and a Stripe
/// SetupIntent fetch concurrently, then walks the user through
/// Screen A (account details) and Screen B (credit card or skip)
/// while the zone provisions in the background.
@MainActor
final class ProvisioningController {

    // MARK: - Dependencies

    private let authController: AuthController
    private let keychain: KeychainService
    private let authClient: AuthClient
    private var autonomyClient: AutonomyClient?

    // MARK: - UI

    private var window: OnboardingWindow?
    private var bridge: ProvisioningBridge?

    // MARK: - Callbacks

    /// Called when provisioning completes and the zone is ready.
    /// Parameters are (zoneUrl, zoneSessionToken).
    var onComplete: ((String, String) -> Void)?

    /// Called when a non-recoverable error occurs. The provisioning UI
    /// already shows the error with a retry button; this callback is
    /// for the AppDelegate to log or take additional action.
    var onError: ((Error) -> Void)?

    // MARK: - State

    /// The Autonomy session token from Autonomy Account login.
    private var autonomyToken: String?

    /// Whether a provisioning attempt is currently in progress.
    private var isRunning = false

    /// Stripe SetupIntent info fetched in parallel with provisioning.
    private var stripeSetupInfo: StripeSetupInfo?

    /// Background provisioning result, set when polling completes.
    private var provisioningResult: ProvisioningStatus?

    /// Whether background provisioning polling is still running.
    private var isPolling = false

    /// Continuation for awaiting user action on Screen A.
    private var accountContinuation: CheckedContinuation<(String, String, String?), Never>?

    /// Continuation for awaiting user action on Screen B.
    /// Returns the setupIntentId if the user added a card, or nil if skipped.
    private var paymentContinuation: CheckedContinuation<String?, Never>?

    // MARK: - Init

    /// Create a provisioning controller.
    ///
    /// - Parameters:
    ///   - keychain: Keychain service for storing tokens and zone URL.
    ///   - authClient: Client for redeeming the admin token on the zone.
    ///   - authController: Controller for the Autonomy Account login flow.
    ///     Created automatically if not provided.
    init(
        keychain: KeychainService = KeychainService(),
        authClient: AuthClient = AuthClient(),
        authController: AuthController? = nil
    ) {
        self.keychain = keychain
        self.authClient = authClient
        self.authController = authController ?? AuthController()
    }

    // MARK: - Window management

    /// Show the provisioning window with the bundled HTML page.
    func showWindow() {
        if window == nil {
            let provBridge = ProvisioningBridge()
            let win = OnboardingWindow(bridge: provBridge)
            provBridge.webView = win.webView

            provBridge.onGetStarted = { [weak self] in
                self?.start()
            }
            provBridge.onRetry = { [weak self] in
                self?.start()
            }
            provBridge.onAccountDetails = { [weak self] firstName, lastName, company in
                self?.accountContinuation?.resume(returning: (firstName, lastName, company))
                self?.accountContinuation = nil
            }
            provBridge.onSubmitPayment = { [weak self] setupIntentId in
                self?.paymentContinuation?.resume(returning: setupIntentId)
                self?.paymentContinuation = nil
            }
            provBridge.onSkipPayment = { [weak self] in
                self?.paymentContinuation?.resume(returning: nil)
                self?.paymentContinuation = nil
            }
            provBridge.onOpenExternal = { url in
                NSWorkspace.shared.open(url)
            }

            bridge = provBridge
            window = win
        }

        loadProvisioningHTML()
        window?.present()
    }

    /// Dismiss the provisioning window and clean up.
    func dismissWindow() {
        authController.cancel()
        window?.dismiss()
        window = nil
        bridge = nil
    }

    // MARK: - Provisioning flow

    /// Start (or restart) the full provisioning flow.
    ///
    /// Called when the user clicks "Get Started" or "Retry". Runs the
    /// full parallel sequence:
    ///   1. Auth login
    ///   2. Fire provisioning + SetupIntent fetch in parallel
    ///   3. Screen A: collect account details while zone provisions
    ///   4. Screen B: credit card or skip trial
    ///   5. Wait for zone if still provisioning
    ///   6. Redeem admin token → hand off to onboarding
    private func start() {
        guard !isRunning else { return }
        isRunning = true

        Task {
            defer { isRunning = false }

            do {
                // Step 1: Autonomy Account login
                bridge?.pushAuthStarted()
                #if DEBUG
                    Log.debug("[Provisioning] Starting Autonomy Account login")
                #endif
                let token = try await authController.login()
                self.autonomyToken = token

                // Store the Autonomy token for future API calls (trial checks).
                keychain.saveAutonomyToken(token)

                bridge?.pushAuthComplete()
                #if DEBUG
                    Log.debug("[Provisioning] Auth complete, starting parallel work")
                #endif
                let client = AutonomyClient(token: token)
                self.autonomyClient = client

                // Step 2: Fire provisioning AND SetupIntent in parallel.
                // Provisioning starts polling in the background; SetupIntent
                // fetches the Stripe keys we'll need for Screen B.
                self.provisioningResult = nil
                self.isPolling = true

                let provisioningTask = Task { [weak self] () -> ProvisioningStatus in
                    let initial = try await client.provision()
                    if initial.isReady {
                        self?.provisioningResult = initial
                        self?.isPolling = false
                        return initial
                    }
                    let result =
                        try await self?.pollUntilReady(client: client)
                        ?? initial
                    self?.provisioningResult = result
                    self?.isPolling = false
                    return result
                }

                let setupIntentTask = Task {
                    try await client.createSetupIntent()
                }

                // Start pushing provisioning progress to the UI.
                // The progress bar is visible at the bottom of Screens A and B.
                let progressTask = Task {
                    await self.pushProgressUpdates()
                }

                // Step 3: Show Screen A (account details + plan).
                bridge?.pushAccountSetup()
                #if DEBUG
                    Log.debug("[Provisioning] Showing Screen A (account details)")
                #endif

                let (firstName, lastName, company) = await waitForAccountDetails()

                // Save account details to orchestrator.
                #if DEBUG
                    Log.debug("[Provisioning] Saving account details")
                #endif
                try await client.saveAccount(
                    firstName: firstName,
                    lastName: lastName,
                    company: company
                )

                // Step 4: Show Screen B (credit card).
                // Fetch the SetupIntent result. If it failed, log the
                // error and skip straight to the card-skip path (user
                // can still start their trial).
                var setupInfo: StripeSetupInfo?
                do {
                    setupInfo = try await setupIntentTask.value
                    self.stripeSetupInfo = setupInfo
                } catch {
                    #if DEBUG
                        Log.debug(
                            "[Provisioning] SetupIntent fetch failed: \(error.localizedDescription)"
                        )
                    #endif
                    // Screen B will show without the Stripe form; user
                    // can only skip. We still show the screen so the
                    // flow isn't jarring.
                }

                if let info = setupInfo {
                    bridge?.pushCreditCard(
                        clientSecret: info.clientSecret,
                        publishableKey: info.publishableKey
                    )
                } else {
                    // No Stripe info available — show Screen B in
                    // skip-only mode (no card form).
                    bridge?.pushCreditCard(clientSecret: "", publishableKey: "")
                }
                #if DEBUG
                    Log.debug("[Provisioning] Showing Screen B (credit card)")
                #endif

                let setupIntentId = await waitForPaymentAction()

                // Handle user's payment decision. If they submit a card
                // and confirmation fails, let them retry or skip.
                var paymentAction = setupIntentId
                while let intentId = paymentAction {
                    #if DEBUG
                        Log.debug("[Provisioning] Confirming payment with orchestrator")
                    #endif
                    do {
                        try await client.confirmPayment(setupIntentId: intentId)
                        bridge?.pushPaymentSuccess()
                        break  // Success — exit the retry loop.
                    } catch {
                        #if DEBUG
                            Log.debug(
                                "[Provisioning] Payment confirmation failed: \(error.localizedDescription)"
                            )
                        #endif
                        bridge?.pushPaymentError(message: error.localizedDescription)
                        // Re-await: user can retry the card or skip.
                        paymentAction = await waitForPaymentAction()
                    }
                }

                if paymentAction == nil {
                    #if DEBUG
                        Log.debug("[Provisioning] User skipped adding a card")
                    #endif
                }

                // Step 5: Wait for provisioning if still in progress.
                progressTask.cancel()

                let result: ProvisioningStatus
                if let cached = self.provisioningResult {
                    result = cached
                } else {
                    // Zone not ready yet — show the spinner screen while
                    // we wait for the background provisioning task.
                    bridge?.pushProvisioningProgress(message: "Finishing setup…")
                    showProvisioningScreen()
                    #if DEBUG
                        Log.debug("[Provisioning] Waiting for zone to be ready")
                    #endif
                    result = try await provisioningTask.value
                }

                // Step 6: Redeem and hand off.
                try await completeProvisioning(status: result)

            } catch let error as AuthControllerError where error == .userCancelled {
                #if DEBUG
                    Log.debug("[Provisioning] User cancelled login")
                #endif
                bridge?.pushAuthError(message: "Login was cancelled. Tap Get Started to try again.")

            } catch {
                #if DEBUG
                    Log.debug("[Provisioning] Error: \(error.localizedDescription)")
                #endif
                bridge?.pushProvisioningError(message: error.localizedDescription)
                onError?(error)
            }
        }
    }

    // MARK: - User interaction continuations

    /// Wait for the user to submit account details on Screen A.
    ///
    /// Returns (firstName, lastName, company) when the bridge receives
    /// the `accountDetails` action from JavaScript.
    private func waitForAccountDetails() async -> (String, String, String?) {
        await withCheckedContinuation { continuation in
            self.accountContinuation = continuation
        }
    }

    /// Wait for the user to submit a card or skip on Screen B.
    ///
    /// Returns the setupIntentId if a card was submitted, or nil if
    /// the user chose to skip.
    private func waitForPaymentAction() async -> String? {
        await withCheckedContinuation { continuation in
            self.paymentContinuation = continuation
        }
    }

    // MARK: - Background progress

    /// Push provisioning progress messages to the UI while screens
    /// are displayed. Runs until the provisioning task completes
    /// (detected via `provisioningResult` being set) or this task
    /// is cancelled.
    private func pushProgressUpdates() async {
        let messages = [
            (delay: 5, message: "Creating your server…"),
            (delay: 10, message: "Installing FreeFlow…"),
            (delay: 20, message: "Configuring your server…"),
            (delay: 30, message: "Almost ready…"),
        ]

        var elapsed = 0
        var messageIndex = 0

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            elapsed += 1

            if messageIndex < messages.count && elapsed >= messages[messageIndex].delay {
                bridge?.pushProvisioningProgress(message: messages[messageIndex].message)
                messageIndex += 1
            }

            // The provisioning task sets provisioningResult when done.
            if self.provisioningResult != nil {
                bridge?.pushProvisioningProgress(message: "Server ready")
                return
            }
        }
    }

    // MARK: - Polling

    /// Poll `GET /api/freeflow/status` every 3 seconds until the zone
    /// is ready or an error occurs.
    ///
    /// Progress messages are now handled by `pushProgressUpdates` so
    /// the polling loop is decoupled from UI updates.
    ///
    /// - Parameter client: The Autonomy API client.
    /// - Returns: The final `ProvisioningStatus` with status "ready".
    /// - Throws: `AutonomyError.provisioningFailed` if the server
    ///   reports an error, or if polling times out after 5 minutes.
    private func pollUntilReady(client: AutonomyClient) async throws -> ProvisioningStatus {
        let maxAttempts = 100  // 5 minutes at 3-second intervals

        for _ in 0..<maxAttempts {
            let result = try await client.status()

            if result.isReady {
                return result
            }

            if result.isError {
                throw AutonomyError.provisioningFailed(
                    result.message ?? "Unknown error"
                )
            }

            try await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
        }

        throw AutonomyError.provisioningFailed(
            "Setup is taking longer than expected. Please try again."
        )
    }

    // MARK: - Completion

    /// Finish provisioning: store the zone URL, redeem the admin token,
    /// and hand off to the existing onboarding flow.
    ///
    /// - Parameter status: The "ready" provisioning status containing
    ///   the zone URL and admin token.
    private func completeProvisioning(status: ProvisioningStatus) async throws {
        guard let zoneUrl = status.zoneUrl, let adminToken = status.adminToken else {
            throw AutonomyError.provisioningFailed("Missing zone URL or admin token")
        }

        // Step 4: Store zone URL in Keychain.
        bridge?.pushProvisioningProgress(message: "Almost ready…")
        keychain.saveServiceURL(zoneUrl)

        // Step 5: Redeem admin token on the zone to get a zone session.
        #if DEBUG
            Log.debug("[Provisioning] Redeeming admin token on zone")
        #endif
        let redeemResult: AuthClient.RedeemResult
        do {
            redeemResult = try await authClient.redeemInvite(
                serviceURL: zoneUrl,
                token: adminToken
            )
        } catch {
            #if DEBUG
                Log.debug("[Provisioning] Redeem failed: \(error)")
            #endif
            throw error
        }
        keychain.saveSessionToken(redeemResult.sessionToken)

        // Step 6: Notify the UI and hand off.
        bridge?.pushProvisioningReady()
        #if DEBUG
            Log.debug("[Provisioning] Zone ready, handing off to onboarding")
        #endif

        // Brief delay so the user sees the success screen.
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

        onComplete?(zoneUrl, redeemResult.sessionToken)
    }

    // MARK: - Resume

    /// Check whether a previous provisioning attempt was interrupted
    /// and resume polling if needed.
    ///
    /// Call this on app launch when an Autonomy token exists in the
    /// Keychain but no zone URL has been stored yet.
    func resumeIfNeeded() {
        guard let token = keychain.autonomyToken(),
            keychain.serviceURL() == nil
        else {
            return
        }

        #if DEBUG
            Log.debug("[Provisioning] Resuming interrupted provisioning")
        #endif
        self.autonomyToken = token
        self.autonomyClient = AutonomyClient(token: token)
        isRunning = true

        Task {
            defer { isRunning = false }

            do {
                bridge?.pushAuthComplete()
                bridge?.pushProvisioningProgress(message: "Resuming setup…")
                let result = try await pollUntilReady(client: autonomyClient!)
                try await completeProvisioning(status: result)
            } catch {
                #if DEBUG
                    Log.debug("[Provisioning] Resume failed: \(error.localizedDescription)")
                #endif
                bridge?.pushProvisioningError(message: error.localizedDescription)
                onError?(error)
            }
        }
    }

    // MARK: - UI helpers

    /// Switch the web view to the provisioning spinner screen.
    ///
    /// Used when the billing screens are done but the zone is still
    /// provisioning. Evaluates JavaScript to call `showScreen('provisioning')`.
    private func showProvisioningScreen() {
        let script = """
            if (typeof showScreen === 'function') { showScreen('provisioning'); }
            """
        window?.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - HTML loading

    /// Load the bundled provisioning HTML page into the web view.
    private func loadProvisioningHTML() {
        guard
            let htmlURL = Bundle.main.url(
                forResource: "provisioning",
                withExtension: "html"
            )
        else {
            #if DEBUG
                Log.debug("[Provisioning] provisioning.html not found in bundle")
            #endif
            return
        }

        window?.webView.loadFileURL(
            htmlURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
    }
}

// MARK: - AuthControllerError Equatable

extension AuthControllerError: Equatable {
    static func == (lhs: AuthControllerError, rhs: AuthControllerError) -> Bool {
        switch (lhs, rhs) {
        case (.userCancelled, .userCancelled):
            return true
        case (.invalidCallback, .invalidCallback):
            return true
        case (.authFailed(let a), .authFailed(let b)):
            return a == b
        default:
            return false
        }
    }
}
