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
    /// entire sequence: auth → provision → poll → redeem → complete.
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

                // Step 2: Trigger provisioning
                bridge?.pushAuthComplete()
                #if DEBUG
                    Log.debug("[Provisioning] Auth complete, triggering provisioning")
                #endif
                let client = AutonomyClient(token: token)
                self.autonomyClient = client

                let initial = try await client.provision()
                if initial.isReady {
                    // Zone already exists — skip polling.
                    try await completeProvisioning(status: initial)
                    return
                }

                // Step 3: Poll until ready
                bridge?.pushProvisioningProgress(message: "Creating your server…")
                #if DEBUG
                    Log.debug("[Provisioning] Polling for readiness")
                #endif
                let result = try await pollUntilReady(client: client)
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

    // MARK: - Polling

    /// Poll `GET /api/freeflow/status` every 3 seconds until the zone
    /// is ready or an error occurs. Shows progress messages at timed
    /// milestones.
    ///
    /// - Parameter client: The Autonomy API client.
    /// - Returns: The final `ProvisioningStatus` with status "ready".
    /// - Throws: `AutonomyError.provisioningFailed` if the server
    ///   reports an error, or if polling times out after 3 minutes.
    private func pollUntilReady(client: AutonomyClient) async throws -> ProvisioningStatus {
        let maxAttempts = 60  // 3 minutes at 3-second intervals
        let milestones: [(attempt: Int, message: String)] = [
            (5, "Installing FreeFlow…"),
            (15, "Configuring your server…"),
            (30, "Almost ready…"),
        ]

        for attempt in 0..<maxAttempts {
            let result = try await client.status()

            if result.isReady {
                return result
            }

            if result.isError {
                throw AutonomyError.provisioningFailed(
                    result.message ?? "Unknown error"
                )
            }

            // Update progress message at milestones.
            if let milestone = milestones.first(where: { $0.attempt == attempt }) {
                bridge?.pushProvisioningProgress(message: milestone.message)
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
