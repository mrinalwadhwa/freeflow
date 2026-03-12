import Foundation

/// HTTP client for the Autonomy provisioning API.
///
/// Communicates with the central Autonomy service at my.autonomy.computer
/// to trigger zone provisioning and poll for readiness. Uses a bearer
/// token obtained from the Autonomy Account login flow.
///
/// Endpoints:
///   - `POST /api/freeflow/provision` — trigger zone creation
///   - `GET /api/freeflow/status` — poll until the zone is ready
///   - `POST /api/freeflow/account` — save account details (name, company)
///   - `POST /api/freeflow/setup-intent` — create Stripe SetupIntent
///   - `POST /api/freeflow/confirm-payment` — confirm payment method
public final class AutonomyClient: Sendable {

    private let baseURL: String
    private let token: String
    private let session: URLSession

    /// Create a client for the Autonomy API.
    ///
    /// - Parameters:
    ///   - token: The Autonomy session token from Autonomy Account login.
    ///   - baseURL: Override the Autonomy URL (useful for testing).
    ///   - session: URLSession to use for requests.
    public init(
        token: String,
        baseURL: String = "https://my.autonomy.computer",
        session: URLSession = .shared
    ) {
        self.token = token
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Provision

    /// Trigger zone provisioning for the authenticated user.
    ///
    /// On first call, Autonomy starts creating a new zone and returns
    /// `status: "provisioning"`. If the zone already exists and is
    /// healthy, it returns `status: "ready"` with the zone URL and
    /// admin token.
    ///
    /// - Returns: The current provisioning status.
    /// - Throws: `AutonomyError` on auth or server failures.
    public func provision() async throws -> ProvisioningStatus {
        guard let url = URL(string: "\(baseURL)/api/freeflow/provision") else {
            throw AutonomyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        return try await perform(request)
    }

    // MARK: - Status

    /// Poll the provisioning status for the authenticated user.
    ///
    /// Returns one of:
    ///   - `not_provisioned` — provision has not been called yet
    ///   - `provisioning` — zone creation in progress
    ///   - `ready` — zone is up, includes zone_url and admin_token
    ///   - `error` — provisioning failed, includes message
    ///
    /// When status is `ready`, the response also includes trial info:
    /// `trial`, `trial_days_remaining`, and `has_credit_card`.
    ///
    /// - Returns: The current provisioning status.
    /// - Throws: `AutonomyError` on auth or server failures.
    public func status() async throws -> ProvisioningStatus {
        guard let url = URL(string: "\(baseURL)/api/freeflow/status") else {
            throw AutonomyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return try await perform(request)
    }

    // MARK: - Account

    /// Save account details on the Autonomy user record.
    ///
    /// Stores first name, last name, optional company, and marks
    /// `accepted_tos: true`. Must be called before `confirmPayment`
    /// so the Stripe customer has a name.
    ///
    /// - Parameters:
    ///   - firstName: The user's first name (required, non-empty).
    ///   - lastName: The user's last name (required, non-empty).
    ///   - company: The user's company name (optional).
    /// - Throws: `AutonomyError` on validation or server failures.
    public func saveAccount(
        firstName: String,
        lastName: String,
        company: String? = nil
    ) async throws {
        guard let url = URL(string: "\(baseURL)/api/freeflow/account") else {
            throw AutonomyError.invalidURL
        }

        var body: [String: String] = [
            "first_name": firstName,
            "last_name": lastName,
        ]
        if let company, !company.isEmpty {
            body["company"] = company
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutonomyError.invalidResponse
        }

        #if DEBUG
            Log.debug(
                "[AutonomyClient] POST /api/freeflow/account → \(httpResponse.statusCode)"
            )
        #endif

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw AutonomyError.unauthorized
        case 422:
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AutonomyError.validationError(detail)
        default:
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AutonomyError.serverError(httpResponse.statusCode, detail)
        }
    }

    // MARK: - Stripe Setup

    /// Create a Stripe SetupIntent for collecting a credit card.
    ///
    /// The orchestrator creates a Stripe customer (if one doesn't exist)
    /// and a SetupIntent, then returns the client secret and publishable
    /// key needed to mount Stripe's Payment Element in a web view.
    ///
    /// Call this in parallel with provisioning so the Stripe form is
    /// ready by the time the user reaches the credit card screen.
    ///
    /// - Returns: A `StripeSetupInfo` with the client secret and
    ///   publishable key for Stripe.js.
    /// - Throws: `AutonomyError` on auth or server failures.
    public func createSetupIntent() async throws -> StripeSetupInfo {
        guard let url = URL(string: "\(baseURL)/api/freeflow/setup-intent") else {
            throw AutonomyError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutonomyError.invalidResponse
        }

        #if DEBUG
            Log.debug(
                "[AutonomyClient] POST /api/freeflow/setup-intent → \(httpResponse.statusCode)"
            )
        #endif

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            return try decoder.decode(StripeSetupInfo.self, from: data)
        case 401:
            throw AutonomyError.unauthorized
        default:
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AutonomyError.serverError(httpResponse.statusCode, detail)
        }
    }

    /// Confirm a Stripe SetupIntent after the user submits their card.
    ///
    /// Called after Stripe.js `confirmSetup()` succeeds in the web view.
    /// The orchestrator retrieves the SetupIntent from Stripe, stores
    /// the payment method, and marks the user as having a credit card.
    ///
    /// - Parameter setupIntentId: The Stripe SetupIntent ID
    ///   (e.g. `seti_1234...`) returned by Stripe.js after confirmation.
    /// - Throws: `AutonomyError` on auth or server failures.
    public func confirmPayment(setupIntentId: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/freeflow/confirm-payment") else {
            throw AutonomyError.invalidURL
        }

        let body: [String: String] = [
            "setup_intent_id": setupIntentId
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutonomyError.invalidResponse
        }

        #if DEBUG
            Log.debug(
                "[AutonomyClient] POST /api/freeflow/confirm-payment → \(httpResponse.statusCode)"
            )
        #endif

        switch httpResponse.statusCode {
        case 200:
            return
        case 401:
            throw AutonomyError.unauthorized
        default:
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AutonomyError.serverError(httpResponse.statusCode, detail)
        }
    }

    // MARK: - Private

    private func perform(_ request: URLRequest) async throws -> ProvisioningStatus {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutonomyError.invalidResponse
        }

        #if DEBUG
            Log.debug(
                "[AutonomyClient] \(request.httpMethod ?? "?") \(request.url?.path ?? "?") → \(httpResponse.statusCode)"
            )
        #endif

        switch httpResponse.statusCode {
        case 200:
            let decoder = JSONDecoder()
            return try decoder.decode(ProvisioningStatus.self, from: data)
        case 401:
            throw AutonomyError.unauthorized
        case 402:
            throw AutonomyError.trialExpired
        default:
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AutonomyError.serverError(httpResponse.statusCode, detail)
        }
    }
}

// MARK: - Response model

/// Provisioning status returned by the Autonomy API.
public struct ProvisioningStatus: Decodable, Sendable {
    /// One of: "not_provisioned", "provisioning", "ready", "error".
    public let status: String

    /// The zone's base URL. Present when status is "ready".
    public let zoneUrl: String?

    /// Admin token for redeeming on the zone. Present when status is "ready".
    public let adminToken: String?

    /// Whether the user is on a trial plan.
    public let trial: Bool?

    /// Days remaining in the trial period.
    public let trialDaysRemaining: Int?

    /// Whether the user has a credit card on file.
    public let hasCreditCard: Bool?

    /// The user's email on the Autonomy Account. Present when the
    /// orchestrator includes it in the response (e.g. from Auth0).
    public let email: String?

    /// Error message. Present when status is "error".
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case zoneUrl = "zone_url"
        case adminToken = "admin_token"
        case trial
        case trialDaysRemaining = "trial_days_remaining"
        case hasCreditCard = "has_credit_card"
        case email
        case message
    }

    /// Whether provisioning is complete and the zone is reachable.
    public var isReady: Bool { status == "ready" }

    /// Whether provisioning is still in progress.
    public var isProvisioning: Bool {
        status == "provisioning" || status == "not_provisioned"
    }

    /// Whether provisioning failed.
    public var isError: Bool { status == "error" }
}

// MARK: - Stripe Setup Info

/// Response from `POST /api/freeflow/setup-intent`.
///
/// Contains the Stripe client secret and publishable key needed to
/// mount a Stripe Payment Element in a web view and confirm the
/// SetupIntent client-side via Stripe.js.
public struct StripeSetupInfo: Decodable, Sendable {
    /// The SetupIntent client secret for Stripe.js `confirmSetup()`.
    public let clientSecret: String

    /// The Stripe publishable key for initializing `Stripe(pk)`.
    public let publishableKey: String

    enum CodingKeys: String, CodingKey {
        case clientSecret = "client_secret"
        case publishableKey = "publishable_key"
    }
}

// MARK: - Errors

/// Errors from Autonomy API operations.
public enum AutonomyError: Error, LocalizedError, Sendable {
    /// The URL could not be constructed.
    case invalidURL
    /// The server response was not an HTTP response.
    case invalidResponse
    /// The session token is expired or invalid (HTTP 401).
    case unauthorized
    /// The user's trial has expired (HTTP 402).
    case trialExpired
    /// The server returned an unexpected status code.
    case serverError(Int, String)
    /// Provisioning failed with a message from the server.
    case provisioningFailed(String)
    /// The server rejected input as invalid (HTTP 422).
    case validationError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL"
        case .invalidResponse:
            return "Invalid server response"
        case .unauthorized:
            return "Session expired — please sign in again"
        case .trialExpired:
            return "Free trial has ended"
        case .serverError(let code, _):
            return "Server error (\(code))"
        case .provisioningFailed(let msg):
            return "Setup failed: \(msg)"
        case .validationError(let detail):
            return "Invalid input: \(detail)"
        }
    }
}
