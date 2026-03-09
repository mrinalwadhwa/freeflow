import Foundation
import Testing

@testable import VoiceKit

// MARK: - KeychainService tests

@Suite(
    "KeychainService",
    .enabled(if: ProcessInfo.processInfo.environment["VOICE_TEST_KEYCHAIN"] == "1"))
struct KeychainServiceTests {

    /// Use a unique service name per test run to avoid cross-contamination
    /// with the real app's Keychain entries.
    private func makeKeychain() -> KeychainService {
        let id = UUID().uuidString.prefix(8)
        return KeychainService(service: "computer.autonomy.voice.test.\(id)")
    }

    @Test("Save and retrieve session token")
    func saveAndRetrieveToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        #expect(keychain.sessionToken() == nil)

        let saved = keychain.saveSessionToken("tok_abc123")
        #expect(saved)

        #expect(keychain.sessionToken() == "tok_abc123")
    }

    @Test("Save and retrieve service URL")
    func saveAndRetrieveURL() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        #expect(keychain.serviceURL() == nil)

        let saved = keychain.saveServiceURL("https://example.com")
        #expect(saved)

        #expect(keychain.serviceURL() == "https://example.com")
    }

    @Test("Overwrite existing token")
    func overwriteToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("old_token")
        keychain.saveSessionToken("new_token")

        #expect(keychain.sessionToken() == "new_token")
    }

    @Test("Overwrite existing service URL")
    func overwriteURL() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveServiceURL("https://old.example.com")
        keychain.saveServiceURL("https://new.example.com")

        #expect(keychain.serviceURL() == "https://new.example.com")
    }

    @Test("Delete session token")
    func deleteToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("tok_delete_me")
        #expect(keychain.sessionToken() != nil)

        let deleted = keychain.deleteSessionToken()
        #expect(deleted)
        #expect(keychain.sessionToken() == nil)
    }

    @Test("Delete service URL")
    func deleteURL() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveServiceURL("https://delete.me")
        #expect(keychain.serviceURL() != nil)

        let deleted = keychain.deleteServiceURL()
        #expect(deleted)
        #expect(keychain.serviceURL() == nil)
    }

    @Test("Delete non-existent item succeeds")
    func deleteNonExistent() {
        let keychain = makeKeychain()

        // Deleting something that was never stored should not fail.
        let deleted = keychain.deleteSessionToken()
        #expect(deleted)
    }

    @Test("deleteAll clears both token and URL")
    func deleteAll() {
        let keychain = makeKeychain()

        keychain.saveSessionToken("tok")
        keychain.saveServiceURL("https://url")
        keychain.deleteAll()

        #expect(keychain.sessionToken() == nil)
        #expect(keychain.serviceURL() == nil)
    }

    @Test("Token and URL are independent items")
    func independentItems() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("token_value")
        keychain.saveServiceURL("url_value")

        // Deleting one should not affect the other.
        keychain.deleteSessionToken()
        #expect(keychain.sessionToken() == nil)
        #expect(keychain.serviceURL() == "url_value")
    }

    @Test("Empty string is stored and retrieved")
    func emptyString() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("")
        // An empty string is valid data; it should round-trip.
        #expect(keychain.sessionToken() == "")
    }

    @Test("Long token value round-trips")
    func longToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        let longToken = String(repeating: "a", count: 4096)
        keychain.saveSessionToken(longToken)
        #expect(keychain.sessionToken() == longToken)
    }

    @Test("Two KeychainService instances with same service share data")
    func sharedService() {
        let serviceName = "computer.autonomy.voice.test.shared.\(UUID().uuidString.prefix(8))"
        let keychain1 = KeychainService(service: serviceName)
        let keychain2 = KeychainService(service: serviceName)
        defer { keychain1.deleteAll() }

        keychain1.saveSessionToken("shared_token")
        #expect(keychain2.sessionToken() == "shared_token")
    }

    @Test("Two KeychainService instances with different services are isolated")
    func isolatedServices() {
        let keychain1 = makeKeychain()
        let keychain2 = makeKeychain()
        defer {
            keychain1.deleteAll()
            keychain2.deleteAll()
        }

        keychain1.saveSessionToken("token_1")
        keychain2.saveSessionToken("token_2")

        #expect(keychain1.sessionToken() == "token_1")
        #expect(keychain2.sessionToken() == "token_2")
    }
}

// MARK: - ServiceConfig layered resolution tests

@Suite(
    "ServiceConfig layered resolution",
    .enabled(if: ProcessInfo.processInfo.environment["VOICE_TEST_KEYCHAIN"] == "1"))
struct ServiceConfigLayeredTests {

    private func makeKeychain() -> KeychainService {
        let id = UUID().uuidString.prefix(8)
        return KeychainService(service: "computer.autonomy.voice.test.\(id)")
    }

    @Test("baseURL returns Keychain value when present")
    func baseURLFromKeychain() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveServiceURL("https://my-zone.example.com")
        let config = ServiceConfig(keychain: keychain)

        #expect(config.baseURL == "https://my-zone.example.com")
    }

    @Test("baseURL falls back to env var when Keychain is empty")
    func baseURLFallback() {
        let keychain = makeKeychain()
        let config = ServiceConfig(keychain: keychain)

        // With no Keychain data, should return env var or localhost default.
        // We can't control env vars in tests, but we can verify it's non-empty.
        #expect(!config.baseURL.isEmpty)
    }

    @Test("authHeader prefers session token over API key")
    func authHeaderPrefersToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("session_abc")
        let config = ServiceConfig(keychain: keychain)

        #expect(config.authHeader == "Bearer session_abc")
    }

    @Test("authToken returns session token when present")
    func authTokenFromKeychain() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("raw_token")
        let config = ServiceConfig(keychain: keychain)

        #expect(config.authToken == "raw_token")
    }

    @Test("authToken returns API key when no session token")
    func authTokenFallback() {
        let keychain = makeKeychain()
        let config = ServiceConfig(keychain: keychain)

        // Without Keychain data, authToken is the apiKey (from env or empty).
        #expect(config.authToken == config.apiKey)
    }

    @Test("isConfigured is true with session token")
    func isConfiguredWithToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("tok")
        let config = ServiceConfig(keychain: keychain)

        #expect(config.isConfigured)
    }

    @Test("isOnboarded is true with session token")
    func isOnboardedWithToken() {
        let keychain = makeKeychain()
        defer { keychain.deleteAll() }

        keychain.saveSessionToken("tok")
        let config = ServiceConfig(keychain: keychain)

        #expect(config.isOnboarded)
    }

    @Test("isOnboarded is false without session token")
    func isOnboardedWithoutToken() {
        let keychain = makeKeychain()
        let config = ServiceConfig(keychain: keychain)

        #expect(!config.isOnboarded)
    }

    @Test("sessionToken returns nil when Keychain is empty")
    func sessionTokenNil() {
        let keychain = makeKeychain()
        let config = ServiceConfig(keychain: keychain)

        #expect(config.sessionToken == nil)
    }

    @Test("Static accessors use shared instance")
    func staticAccessors() {
        // Verify the static accessors exist and don't crash.
        // We can't fully control the shared instance's Keychain in tests,
        // but we can verify the accessors are callable.
        let _ = ServiceConfig.baseURL
        let _ = ServiceConfig.apiKey
    }
}

// MARK: - AuthClient tests

@Suite("AuthClient", .serialized)
struct AuthClientTests {

    /// Build a mock URLSession that returns a fixed response.
    private func mockSession(
        data: Data,
        statusCode: Int,
        headers: [String: String] = [:]
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthMockURLProtocol.self]

        AuthMockURLProtocol.handler = { request in
            let url = request.url!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )!
            return (data, response)
        }

        return URLSession(configuration: config)
    }

    @Test("redeemInvite parses success response")
    func redeemInviteSuccess() async throws {
        let body = """
            {"user_id": "usr_123", "has_email": false}
            """.data(using: .utf8)!

        let session = mockSession(
            data: body,
            statusCode: 200,
            headers: ["set-auth-token": "sess_token_xyz"]
        )

        let client = AuthClient(session: session)
        let result = try await client.redeemInvite(
            serviceURL: "https://example.com",
            token: "invite_abc"
        )

        #expect(result.sessionToken == "sess_token_xyz")
        #expect(result.userId == "usr_123")
        #expect(result.hasEmail == false)
    }

    @Test("redeemInvite with email invite")
    func redeemInviteWithEmail() async throws {
        let body = """
            {"user_id": "usr_456", "has_email": true}
            """.data(using: .utf8)!

        let session = mockSession(
            data: body,
            statusCode: 200,
            headers: ["set-auth-token": "sess_email"]
        )

        let client = AuthClient(session: session)
        let result = try await client.redeemInvite(
            serviceURL: "https://example.com",
            token: "invite_email"
        )

        #expect(result.hasEmail == true)
    }

    @Test("redeemInvite throws on 401")
    func redeemInviteUnauthorized() async {
        let body = """
            {"detail": "Invalid invite token"}
            """.data(using: .utf8)!

        let session = mockSession(data: body, statusCode: 401)
        let client = AuthClient(session: session)

        do {
            _ = try await client.redeemInvite(
                serviceURL: "https://example.com",
                token: "bad_token"
            )
            Issue.record("Expected AuthError.serverError")
        } catch let error as AuthClient.AuthError {
            if case .serverError(let code, _) = error {
                #expect(code == 401)
            } else {
                Issue.record("Expected serverError, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("redeemInvite throws when session token header is missing")
    func redeemInviteMissingToken() async {
        let body = """
            {"user_id": "usr_789", "has_email": false}
            """.data(using: .utf8)!

        // No set-auth-token header.
        let session = mockSession(data: body, statusCode: 200)
        let client = AuthClient(session: session)

        do {
            _ = try await client.redeemInvite(
                serviceURL: "https://example.com",
                token: "invite_no_header"
            )
            Issue.record("Expected AuthError.missingSessionToken")
        } catch let error as AuthClient.AuthError {
            if case .missingSessionToken = error {
                // Expected.
            } else {
                Issue.record("Expected missingSessionToken, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("validateSession returns session info on success")
    func validateSessionSuccess() async throws {
        let body = """
            {
                "session": {"token": "sess_tok", "expiresAt": "2026-04-01T00:00:00Z"},
                "user": {
                    "id": "usr_abc",
                    "name": "Test User",
                    "email": "test@example.com",
                    "emailVerified": true
                }
            }
            """.data(using: .utf8)!

        let session = mockSession(data: body, statusCode: 200)
        let client = AuthClient(session: session)

        let result = try await client.validateSession(
            serviceURL: "https://example.com",
            token: "sess_tok"
        )

        #expect(result.userId == "usr_abc")
        #expect(result.name == "Test User")
        #expect(result.email == "test@example.com")
        #expect(result.emailVerified == true)
    }

    @Test("validateSession throws sessionExpired on 401")
    func validateSessionExpired() async {
        let session = mockSession(data: Data(), statusCode: 401)
        let client = AuthClient(session: session)

        do {
            _ = try await client.validateSession(
                serviceURL: "https://example.com",
                token: "expired_tok"
            )
            Issue.record("Expected AuthError.sessionExpired")
        } catch let error as AuthClient.AuthError {
            if case .sessionExpired = error {
                // Expected.
            } else {
                Issue.record("Expected sessionExpired, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("validateSession throws sessionExpired on null body")
    func validateSessionNullBody() async {
        // better-auth returns "null" for invalid sessions.
        let body = "null".data(using: .utf8)!
        let session = mockSession(data: body, statusCode: 200)
        let client = AuthClient(session: session)

        do {
            _ = try await client.validateSession(
                serviceURL: "https://example.com",
                token: "invalid_tok"
            )
            Issue.record("Expected AuthError.sessionExpired")
        } catch let error as AuthClient.AuthError {
            if case .sessionExpired = error {
                // Expected.
            } else {
                Issue.record("Expected sessionExpired, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("validateSession with placeholder email")
    func validateSessionPlaceholder() async throws {
        let body = """
            {
                "session": {"token": "sess_ph"},
                "user": {
                    "id": "usr_ph",
                    "name": "Invited User",
                    "email": "abc123@placeholder.voice.local",
                    "emailVerified": false
                }
            }
            """.data(using: .utf8)!

        let session = mockSession(data: body, statusCode: 200)
        let client = AuthClient(session: session)

        let result = try await client.validateSession(
            serviceURL: "https://example.com",
            token: "sess_ph"
        )

        #expect(result.email == "abc123@placeholder.voice.local")
        #expect(result.emailVerified == false)
    }
}

// MARK: - CapabilitiesService tests

@Suite("CapabilitiesService", .serialized)
struct CapabilitiesServiceTests {

    private func mockSession(
        data: Data,
        statusCode: Int
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapsMockURLProtocol.self]

        CapsMockURLProtocol.handler = { request in
            let url = request.url!
            let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }

        return URLSession(configuration: config)
    }

    @Test("check parses capabilities response")
    func checkSuccess() async throws {
        let body = """
            {
                "invite": true,
                "email_otp": false,
                "require_email": false,
                "require_email_deadline": null,
                "appcast_url": "https://voice.example.com/appcast.xml"
            }
            """.data(using: .utf8)!

        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let session = mockSession(data: body, statusCode: 200)
        let service = CapabilitiesService(session: session, defaults: defaults)

        let caps = try await service.check(serviceURL: "https://example.com")

        #expect(caps.invite == true)
        #expect(caps.emailOtp == false)
        #expect(caps.requireEmail == false)
        #expect(caps.requireEmailDeadline == nil)
        #expect(caps.appcastUrl == "https://voice.example.com/appcast.xml")

        defaults.removePersistentDomain(forName: defaults.volatileDomainNames.first ?? "")
    }

    @Test("check caches result in UserDefaults")
    func checkCaches() async throws {
        let body = """
            {
                "invite": true,
                "email_otp": true,
                "require_email": true,
                "require_email_deadline": "2026-04-01T00:00:00Z",
                "appcast_url": null
            }
            """.data(using: .utf8)!

        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let session = mockSession(data: body, statusCode: 200)
        let service = CapabilitiesService(session: session, defaults: defaults)

        _ = try await service.check(serviceURL: "https://example.com")

        let cached = service.cachedCapabilities
        #expect(cached != nil)
        #expect(cached?.emailOtp == true)
        #expect(cached?.requireEmail == true)
        #expect(cached?.requireEmailDeadline == "2026-04-01T00:00:00Z")
    }

    @Test("cachedCapabilities returns nil before first fetch")
    func cacheEmpty() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let service = CapabilitiesService(defaults: defaults)
        #expect(service.cachedCapabilities == nil)
    }

    @Test("clearCache removes cached capabilities")
    func clearCache() async throws {
        let body = """
            {
                "invite": true,
                "email_otp": false,
                "require_email": false,
                "require_email_deadline": null,
                "appcast_url": null
            }
            """.data(using: .utf8)!

        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let session = mockSession(data: body, statusCode: 200)
        let service = CapabilitiesService(session: session, defaults: defaults)

        _ = try await service.check(serviceURL: "https://example.com")
        #expect(service.cachedCapabilities != nil)

        service.clearCache()
        #expect(service.cachedCapabilities == nil)
    }

    @Test("check throws on server error")
    func checkServerError() async {
        let session = mockSession(data: Data(), statusCode: 500)
        let service = CapabilitiesService(session: session)

        do {
            _ = try await service.check(serviceURL: "https://example.com")
            Issue.record("Expected CapabilitiesError")
        } catch {
            // Expected.
        }
    }

    @Test("emailEnforcement is none when requireEmail is false")
    func enforcementNone() {
        let caps = CapabilitiesService.Capabilities(
            invite: true,
            emailOtp: true,
            requireEmail: false,
            requireEmailDeadline: nil,
            appcastUrl: nil
        )
        #expect(caps.emailEnforcement == .none)
    }

    @Test("emailEnforcement is enforced when deadline is past")
    func enforcementEnforced() {
        let caps = CapabilitiesService.Capabilities(
            invite: true,
            emailOtp: true,
            requireEmail: true,
            requireEmailDeadline: "2020-01-01T00:00:00Z",
            appcastUrl: nil
        )
        #expect(caps.emailEnforcement == .enforced)
    }

    @Test("emailEnforcement is enforced when no deadline set")
    func enforcementEnforcedNoDeadline() {
        let caps = CapabilitiesService.Capabilities(
            invite: true,
            emailOtp: true,
            requireEmail: true,
            requireEmailDeadline: nil,
            appcastUrl: nil
        )
        #expect(caps.emailEnforcement == .enforced)
    }

    @Test("emailEnforcement is gracePeriod when deadline is future")
    func enforcementGracePeriod() {
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86400 * 30))
        let caps = CapabilitiesService.Capabilities(
            invite: true,
            emailOtp: true,
            requireEmail: true,
            requireEmailDeadline: future,
            appcastUrl: nil
        )
        if case .gracePeriod = caps.emailEnforcement {
            // Expected.
        } else {
            Issue.record("Expected gracePeriod, got \(caps.emailEnforcement)")
        }
    }
}

// MARK: - Mock URL protocols
//
// Each test suite gets its own URLProtocol subclass to avoid shared
// mutable state when tests run concurrently. URLSession creates
// protocol instances internally, so the handler must be class-level.

final class AuthMockURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class CapsMockURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
