import Foundation

/// Check and cache server feature availability.
///
/// Calls `GET /api/auth/capabilities` on the VoiceService zone and
/// caches the result in UserDefaults. The cached value is available
/// synchronously for UI decisions (e.g. whether to show email prompt)
/// while the network fetch runs in the background.
public final class CapabilitiesService: @unchecked Sendable {

    private let session: URLSession
    private let defaults: UserDefaults

    /// UserDefaults key for the cached capabilities JSON.
    private static let cacheKey = "computer.autonomy.voice.capabilities"

    public init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.defaults = defaults
    }

    // MARK: - Model

    /// Server capabilities returned by `/api/auth/capabilities`.
    public struct Capabilities: Codable, Sendable, Equatable {
        /// Whether invite-based auth is available.
        public let invite: Bool
        /// Whether email OTP is configured and verified.
        public let emailOtp: Bool
        /// Whether email is required for continued use.
        public let requireEmail: Bool
        /// ISO 8601 deadline after which email is enforced, or nil.
        public let requireEmailDeadline: String?
        /// URL of the Sparkle appcast for auto-updates, or nil.
        public let appcastUrl: String?

        enum CodingKeys: String, CodingKey {
            case invite
            case emailOtp = "email_otp"
            case requireEmail = "require_email"
            case requireEmailDeadline = "require_email_deadline"
            case appcastUrl = "appcast_url"
        }

        /// The email enforcement level based on current time.
        public var emailEnforcement: EmailEnforcement {
            guard requireEmail else { return .none }
            guard let deadlineString = requireEmailDeadline,
                let deadline = ISO8601DateFormatter().date(from: deadlineString)
            else {
                // requireEmail is true but no deadline means enforced now.
                return .enforced
            }
            if Date() >= deadline {
                return .enforced
            }
            return .gracePeriod(deadline: deadline)
        }
    }

    /// Email enforcement level derived from capabilities.
    public enum EmailEnforcement: Sendable, Equatable {
        /// Email is not required.
        case none
        /// Email is required but the deadline has not passed yet.
        case gracePeriod(deadline: Date)
        /// Email is required and the deadline has passed (or no deadline).
        case enforced
    }

    // MARK: - Fetch

    /// Fetch capabilities from the server and update the cache.
    ///
    /// - Parameter serviceURL: Base URL of the VoiceService zone.
    /// - Returns: The fetched capabilities.
    /// - Throws: On network or decoding errors.
    public func check(serviceURL: String) async throws -> Capabilities {
        guard let url = URL(string: "\(serviceURL)/api/auth/capabilities") else {
            throw CapabilitiesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CapabilitiesError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw CapabilitiesError.serverError(statusCode: httpResponse.statusCode)
        }

        let capabilities = try JSONDecoder().decode(Capabilities.self, from: data)
        cacheCapabilities(capabilities)
        return capabilities
    }

    // MARK: - Cache

    /// Return the most recently cached capabilities, or nil if never fetched.
    public var cachedCapabilities: Capabilities? {
        guard let data = defaults.data(forKey: Self.cacheKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Capabilities.self, from: data)
    }

    /// Clear the cached capabilities.
    public func clearCache() {
        defaults.removeObject(forKey: Self.cacheKey)
    }

    private func cacheCapabilities(_ capabilities: Capabilities) {
        if let data = try? JSONEncoder().encode(capabilities) {
            defaults.set(data, forKey: Self.cacheKey)
        }
    }

    // MARK: - Errors

    public enum CapabilitiesError: Error, Sendable {
        case invalidURL
        case invalidResponse
        case serverError(statusCode: Int)
    }
}
