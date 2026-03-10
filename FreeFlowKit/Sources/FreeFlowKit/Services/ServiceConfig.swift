import Foundation

/// Resolve service connection settings from layered sources.
///
/// Resolution order (highest priority first):
///   1. Keychain (session token) + Keychain (service URL)
///   2. Environment variables (FREEFLOW_SERVICE_URL, FREEFLOW_API_KEY)
///
/// Layer 1 is populated during onboarding when the user redeems an
/// invite link. Layer 2 preserves the existing dev workflow where
/// env vars are set at launch.
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
    /// Checks Keychain first, then falls back to the FREEFLOW_SERVICE_URL
    /// environment variable, then to localhost for local development.
    public var baseURL: String {
        if let url = keychain.serviceURL(), !url.isEmpty {
            return url
        }
        return ProcessInfo.processInfo.environment["FREEFLOW_SERVICE_URL"]
            ?? "http://localhost:8000"
    }

    // MARK: - Auth

    /// Session token from the Keychain (set during onboarding).
    public var sessionToken: String? {
        keychain.sessionToken()
    }

    /// API key from the FREEFLOW_API_KEY environment variable (dev workflow).
    public var apiKey: String {
        ProcessInfo.processInfo.environment["FREEFLOW_API_KEY"] ?? ""
    }

    /// Authorization header value for HTTP requests.
    ///
    /// Returns `Bearer <session_token>` if a Keychain token exists,
    /// otherwise `Bearer <api_key>` from the environment variable.
    /// Returns an empty string only when neither source is available.
    public var authHeader: String {
        if let token = sessionToken, !token.isEmpty {
            return "Bearer \(token)"
        }
        let key = apiKey
        if !key.isEmpty {
            return "Bearer \(key)"
        }
        return ""
    }

    /// The raw token used for authentication (session token or API key).
    ///
    /// Providers that need the bare token (e.g. for WebSocket auth)
    /// use this instead of the full Authorization header.
    public var authToken: String {
        if let token = sessionToken, !token.isEmpty {
            return token
        }
        return apiKey
    }

    /// Whether valid credentials are available from any source.
    public var isConfigured: Bool {
        if let token = sessionToken, !token.isEmpty { return true }
        if !apiKey.isEmpty { return true }
        return false
    }

    /// Whether the config comes from Keychain (onboarding) rather
    /// than environment variables (dev workflow).
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

    /// API key from the shared instance.
    ///
    /// Convenience accessor for call sites that don't hold a reference
    /// to a specific `ServiceConfig` instance.
    public static var apiKey: String { shared.apiKey }
}
