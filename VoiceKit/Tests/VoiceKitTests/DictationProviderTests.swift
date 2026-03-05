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
}
