import Foundation

/// Resolve service connection settings from the Keychain.
///
/// Credentials are populated during onboarding when the user redeems
/// an invite link or the bootstrap token. The Keychain stores the
/// session token and service URL as separate items under the service
/// name `computer.autonomy.freeflow`.
public final class ServiceConfig: @unchecked Sendable {

    /// Shared instance used by service providers when no explicit
    /// config is injected.
    public static let shared = ServiceConfig()

    private let keychain: KeychainService

    public init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    // MARK: - Base URL

    /// Base URL of the FreeFlowService zone.
    ///
    /// Checks Keychain first, then falls back to localhost for local
    /// development.
    public var baseURL: String {
        if let url = keychain.serviceURL(), !url.isEmpty {
            return url
        }
        return "http://localhost:8000"
    }

    // MARK: - Auth

    /// Session token from the Keychain (set during onboarding).
    public var sessionToken: String? {
        keychain.sessionToken()
    }

    /// Authorization header value for HTTP requests.
    ///
    /// Returns `Bearer <session_token>` if a Keychain token exists,
    /// or an empty string when no credentials are available.
    public var authHeader: String {
        if let token = sessionToken, !token.isEmpty {
            return "Bearer \(token)"
        }
        return ""
    }

    /// The raw token used for authentication.
    ///
    /// Providers that need the bare token (e.g. for WebSocket auth)
    /// use this instead of the full Authorization header.
    public var authToken: String {
        if let token = sessionToken, !token.isEmpty {
            return token
        }
        return ""
    }

    /// Whether valid credentials are available.
    public var isConfigured: Bool {
        if let token = sessionToken, !token.isEmpty { return true }
        return false
    }

    /// Whether the config comes from Keychain (onboarding complete).
    public var isOnboarded: Bool {
        if let token = sessionToken, !token.isEmpty { return true }
        return false
    }

    // MARK: - Static convenience accessors

    /// Base URL from the shared instance.
    ///
    /// Convenience accessor for call sites that don't hold a reference
    /// to a specific `ServiceConfig` instance.
    public static var baseURL: String { shared.baseURL }
}
