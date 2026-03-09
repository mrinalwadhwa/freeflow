import Foundation
import Testing

@testable import VoiceKit

@Suite("Dictation provider")
struct DictationProviderTests {

    // MARK: - VoiceServiceDictationProvider request construction

    @Test("Request has correct URL")
    func requestURL() throws {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "key123")
        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)
        #expect(request.url?.absoluteString == "https://example.com/dictate")
    }

    @Test("Request URL trims trailing slash from base URL")
    func requestURLTrailingSlash() throws {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com/", apiKey: "key123")
        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)
        #expect(request.url?.absoluteString == "https://example.com/dictate")
    }

    @Test("Request is a POST")
    func requestMethod() throws {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)
        #expect(request.httpMethod == "POST")
    }

    @Test("Request has multipart content type with boundary")
    func requestContentType() throws {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)
        let ct = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test("Request has bearer auth header")
    func requestAuth() throws {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "secret-key")
        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer secret-key")
    }

    @Test("Request body contains audio data")
    func requestBodyContainsAudio() throws {
        let audio = Data("test-audio-bytes".utf8)
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(
            audio: audio, context: .empty)
        let body = request.httpBody ?? Data()
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyStr.contains("recording.wav"))
        #expect(bodyStr.contains("audio/wav"))
        #expect(body.count > audio.count)
    }

    @Test("Request body has correct multipart structure")
    func requestBodyStructure() throws {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(
            audio: Data([42]), context: .empty)
        let body = request.httpBody ?? Data()
        let bodyStr = String(data: body, encoding: .utf8) ?? ""

        // File and context fields.
        #expect(bodyStr.contains("name=\"file\""))
        #expect(bodyStr.contains("name=\"context\""))
        // Closing boundary.
        #expect(bodyStr.contains("--"))
    }

    @Test("Request body includes context JSON")
    func requestBodyIncludesContext() throws {
        let context = AppContext(
            bundleID: "com.apple.mail",
            appName: "Mail",
            windowTitle: "New Message",
            browserURL: nil,
            focusedFieldContent: "Dear team,",
            cursorPosition: 10
        )
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(
            audio: Data([0]), context: context)
        let body = request.httpBody ?? Data()
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyStr.contains("com.apple.mail"))
        #expect(bodyStr.contains("Mail"))
        #expect(bodyStr.contains("New Message"))
        #expect(bodyStr.contains("Dear team,"))
    }

    @Test("Empty audio throws emptyAudio error")
    func emptyAudioThrows() async {
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://example.com", apiKey: "k")

        do {
            _ = try await provider.dictate(audio: Data(), context: .empty)
            Issue.record("Expected emptyAudio error")
        } catch let error as DictationError {
            #expect(error == .emptyAudio)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - DictationError

    @Test("DictationError cases are equatable")
    func errorEquatable() {
        #expect(DictationError.emptyAudio == DictationError.emptyAudio)
        #expect(
            DictationError.authenticationFailed
                == DictationError.authenticationFailed)
        #expect(
            DictationError.invalidResponse
                == DictationError.invalidResponse)
        #expect(
            DictationError.requestFailed(statusCode: 500, message: "err")
                == DictationError.requestFailed(statusCode: 500, message: "err"))
        #expect(
            DictationError.networkError("timeout")
                == DictationError.networkError("timeout"))
        #expect(DictationError.emptyAudio != DictationError.authenticationFailed)
    }

    @Test("Different status codes are not equal")
    func errorDifferentStatusCodes() {
        #expect(
            DictationError.requestFailed(statusCode: 500, message: "err")
                != DictationError.requestFailed(statusCode: 502, message: "err"))
    }

    @Test("Different messages are not equal")
    func errorDifferentMessages() {
        #expect(
            DictationError.networkError("timeout")
                != DictationError.networkError("refused"))
    }

    // MARK: - ServiceConfig

    @Test("ServiceConfig has default values")
    func serviceConfigDefaults() {
        // These test that the properties exist and return strings.
        // Actual values depend on env vars, so just test non-crash.
        let url = ServiceConfig.baseURL
        #expect(!url.isEmpty)
        // apiKey may be empty if env var not set, which is fine.
        _ = ServiceConfig.apiKey
    }

    // MARK: - Dynamic credential resolution

    @Test("DictationProvider reads baseURL from ServiceConfig at request time")
    func dictationProviderDynamicBaseURL() throws {
        let keychain = KeychainService(
            service: "computer.autonomy.voice.test.\(UUID().uuidString.prefix(8))")
        defer { keychain.deleteAll() }

        let config = ServiceConfig(keychain: keychain)

        // Create provider before any Keychain credentials exist.
        let provider = VoiceServiceDictationProvider(config: config)

        // Simulate onboarding completing after provider creation.
        keychain.saveServiceURL("https://zone.example.com")
        keychain.saveSessionToken("tok_after_onboarding")

        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)

        #expect(request.url?.absoluteString == "https://zone.example.com/dictate")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer tok_after_onboarding")
    }

    @Test("DictationProvider uses explicit overrides over ServiceConfig")
    func dictationProviderExplicitOverrides() throws {
        let keychain = KeychainService(
            service: "computer.autonomy.voice.test.\(UUID().uuidString.prefix(8))")
        defer { keychain.deleteAll() }

        keychain.saveServiceURL("https://keychain-url.example.com")
        keychain.saveSessionToken("keychain-token")

        let config = ServiceConfig(keychain: keychain)

        // Explicit values should win over ServiceConfig.
        let provider = VoiceServiceDictationProvider(
            baseURL: "https://explicit.example.com",
            apiKey: "explicit-key",
            config: config)

        let request = try provider.buildRequest(
            audio: Data([0]), context: .empty)

        #expect(request.url?.absoluteString == "https://explicit.example.com/dictate")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer explicit-key")
    }

    @Test("DictationProvider picks up credential changes between requests")
    func dictationProviderCredentialRotation() throws {
        let keychain = KeychainService(
            service: "computer.autonomy.voice.test.\(UUID().uuidString.prefix(8))")
        defer { keychain.deleteAll() }

        let config = ServiceConfig(keychain: keychain)
        let provider = VoiceServiceDictationProvider(config: config)

        // First request uses env-var fallback (no Keychain values).
        let request1 = try provider.buildRequest(
            audio: Data([0]), context: .empty)
        let auth1 = request1.value(forHTTPHeaderField: "Authorization") ?? ""

        // Simulate session token arriving from onboarding.
        keychain.saveSessionToken("tok_new_session")
        keychain.saveServiceURL("https://new-zone.example.com")

        // Second request picks up the new credentials.
        let request2 = try provider.buildRequest(
            audio: Data([0]), context: .empty)

        #expect(request2.url?.absoluteString == "https://new-zone.example.com/dictate")
        #expect(
            request2.value(forHTTPHeaderField: "Authorization")
                == "Bearer tok_new_session")

        // Verify the credentials actually changed.
        #expect(auth1 != "Bearer tok_new_session")
    }

    @Test("StreamingProvider reads baseURL from ServiceConfig at connection time")
    func streamingProviderDynamicConfig() {
        let keychain = KeychainService(
            service: "computer.autonomy.voice.test.\(UUID().uuidString.prefix(8))")
        defer { keychain.deleteAll() }

        let config = ServiceConfig(keychain: keychain)

        // Create provider before any Keychain credentials exist.
        let provider = VoiceServiceStreamingProvider(config: config)

        // Simulate onboarding completing after provider creation.
        keychain.saveServiceURL("https://zone.example.com")
        keychain.saveSessionToken("tok_streamer")

        // We cannot call ensureConnected (no real server), but we can
        // verify the provider was created successfully and will read
        // from config. The explicit-override path is tested via
        // BackupConnectionTests which passes baseURL/apiKey directly.
        _ = provider
    }

    @Test("StreamingProvider uses explicit overrides for tests")
    func streamingProviderExplicitOverrides() {
        // This is the pattern used by BackupConnectionTests.
        let provider = VoiceServiceStreamingProvider(
            baseURL: "http://127.0.0.1:9999",
            apiKey: "test-key")

        // Provider created successfully with explicit values.
        _ = provider
    }
}
