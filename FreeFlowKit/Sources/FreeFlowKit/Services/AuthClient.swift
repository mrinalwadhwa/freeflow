import Foundation

/// Communicate with the FreeFlowService auth endpoints.
///
/// Provides invite redemption, session validation, and capabilities
/// checking. All methods are async and throw on network or server
/// errors. The caller is responsible for storing tokens and updating
/// ServiceConfig after successful operations.
public final class AuthClient: Sendable {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Invite redemption

    /// Result of redeeming an invite token.
    public struct RedeemResult: Sendable {
        /// Session token for authenticating subsequent requests.
        public let sessionToken: String
        /// The user ID assigned by better-auth.
        public let userId: String
        /// Whether the user has a real email on file (not a placeholder).
        public let hasEmail: Bool
    }

    /// Redeem an invite token to create a user and obtain a session.
    ///
    /// Calls `POST /api/auth/redeem-invite` on the given service URL.
    /// The session token is returned in the `set-auth-token` response
    /// header (better-auth bearer plugin behavior).
    ///
    /// - Parameters:
    ///   - serviceURL: Base URL of the FreeFlowService zone.
    ///   - token: The invite token from the invite link.
    /// - Returns: A `RedeemResult` containing the session token and user info.
    /// - Throws: `AuthError` on failure.
    public func redeemInvite(serviceURL: String, token: String) async throws -> RedeemResult {
        guard let url = URL(string: "\(serviceURL)/api/auth/redeem-invite") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": token])

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.serverError(statusCode: httpResponse.statusCode, detail: detail)
        }

        // Extract session token from the set-auth-token header.
        guard let sessionToken = httpResponse.value(forHTTPHeaderField: "set-auth-token"),
            !sessionToken.isEmpty
        else {
            throw AuthError.missingSessionToken
        }

        // Parse the response body for user info.
        let body = try JSONDecoder().decode(RedeemResponseBody.self, from: data)

        return RedeemResult(
            sessionToken: sessionToken,
            userId: body.userId,
            hasEmail: body.hasEmail
        )
    }

    // MARK: - Session validation

    /// Session information returned by better-auth's get-session endpoint.
    public struct Session: Sendable {
        /// The user ID from the session.
        public let userId: String
        /// The user's display name.
        public let name: String
        /// The user's email (may be a placeholder).
        public let email: String
        /// Whether the email has been verified.
        public let emailVerified: Bool
    }

    /// Validate a session token against the auth service.
    ///
    /// Calls `GET /api/auth/get-session` with the token as a Bearer
    /// header. Returns session info if valid.
    ///
    /// - Parameters:
    ///   - serviceURL: Base URL of the FreeFlowService zone.
    ///   - token: The session token to validate.
    /// - Returns: A `Session` with user info.
    /// - Throws: `AuthError.sessionExpired` if the token is invalid,
    ///   or other `AuthError` variants on failure.
    public func validateSession(serviceURL: String, token: String) async throws -> Session {
        guard let url = URL(string: "\(serviceURL)/api/auth/get-session") else {
            throw AuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw AuthError.sessionExpired
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw AuthError.serverError(statusCode: httpResponse.statusCode, detail: detail)
        }

        // better-auth returns { session: {...}, user: { id, name, email, ... } }
        // or null if the session is invalid.
        let body = try JSONDecoder().decode(GetSessionResponseBody?.self, from: data)

        guard let body, let user = body.user else {
            throw AuthError.sessionExpired
        }

        return Session(
            userId: user.id,
            name: user.name ?? "",
            email: user.email ?? "",
            emailVerified: user.emailVerified ?? false
        )
    }

    // MARK: - Errors

    /// Errors from auth operations.
    public enum AuthError: Error, Sendable {
        /// The URL could not be constructed.
        case invalidURL
        /// The server response was not an HTTP response.
        case invalidResponse
        /// The server returned an error status code.
        case serverError(statusCode: Int, detail: String)
        /// The redeem response did not include a session token header.
        case missingSessionToken
        /// The session token is expired or revoked.
        case sessionExpired
    }

    // MARK: - Response bodies (private)

    private struct RedeemResponseBody: Decodable {
        let userId: String
        let hasEmail: Bool

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case hasEmail = "has_email"
        }
    }

    private struct GetSessionResponseBody: Decodable {
        let session: SessionInfo?
        let user: UserInfo?
    }

    private struct SessionInfo: Decodable {
        let token: String?
        let expiresAt: String?
    }

    private struct UserInfo: Decodable {
        let id: String
        let name: String?
        let email: String?
        let emailVerified: Bool?
    }
}
