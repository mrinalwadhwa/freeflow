import Foundation

/// HTTP client for the Autonomy provisioning API.
///
/// Communicates with the central Autonomy service at my.autonomy.computer
/// to trigger zone provisioning and poll for readiness. Uses a bearer
/// token obtained from the Autonomy Account login flow.
///
/// Two endpoints:
///   - `POST /api/freeflow/provision` — trigger zone creation
///   - `GET /api/freeflow/status` — poll until the zone is ready
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

    // MARK: - Private

    private func perform(_ request: URLRequest) async throws -> ProvisioningStatus {
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AutonomyError.invalidResponse
        }

        let bodyString = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        Log.debug(
            "[AutonomyClient] \(request.httpMethod ?? "?") \(request.url?.path ?? "?") → \(httpResponse.statusCode) body=\(bodyString)"
        )

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

    /// Error message. Present when status is "error".
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case status
        case zoneUrl = "zone_url"
        case adminToken = "admin_token"
        case trial
        case trialDaysRemaining = "trial_days_remaining"
        case hasCreditCard = "has_credit_card"
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
        }
    }
}
