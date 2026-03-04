import Foundation
import Testing

@testable import VoiceKit

@Suite("STT provider")
struct STTProviderTests {

    // MARK: - MockSTTProvider

    @Test("MockSTTProvider returns stubbed text")
    func mockReturnsStubbed() async throws {
        let mock = MockSTTProvider(stubbedText: "Hello world")
        let result = try await mock.transcribe(audio: Data([1, 2, 3]))
        #expect(result == "Hello world")
        #expect(mock.transcribeCallCount == 1)
    }

    @Test("MockSTTProvider records audio data")
    func mockRecordsAudio() async throws {
        let mock = MockSTTProvider()
        let audio1 = Data([10, 20])
        let audio2 = Data([30, 40, 50])

        _ = try await mock.transcribe(audio: audio1)
        _ = try await mock.transcribe(audio: audio2)

        #expect(mock.transcribeCallCount == 2)
        #expect(mock.receivedAudioData.count == 2)
        #expect(mock.receivedAudioData[0] == audio1)
        #expect(mock.receivedAudioData[1] == audio2)
        #expect(mock.lastReceivedAudio == audio2)
    }

    @Test("MockSTTProvider throws stubbed error")
    func mockThrowsError() async {
        let mock = MockSTTProvider()
        mock.stubbedError = STTError.authenticationFailed

        do {
            _ = try await mock.transcribe(audio: Data([1]))
            Issue.record("Expected error")
        } catch {
            #expect(error is STTError)
        }
        #expect(mock.transcribeCallCount == 1)
    }

    @Test("MockSTTProvider reset clears state")
    func mockReset() async throws {
        let mock = MockSTTProvider()
        _ = try await mock.transcribe(audio: Data([1]))
        #expect(mock.transcribeCallCount == 1)

        mock.reset()
        #expect(mock.transcribeCallCount == 0)
        #expect(mock.receivedAudioData.isEmpty)
        #expect(mock.lastReceivedAudio == nil)
    }

    @Test("MockSTTProvider allows changing stubbed text between calls")
    func mockMutableStub() async throws {
        let mock = MockSTTProvider(stubbedText: "first")
        let r1 = try await mock.transcribe(audio: Data([1]))
        #expect(r1 == "first")

        mock.stubbedText = "second"
        let r2 = try await mock.transcribe(audio: Data([2]))
        #expect(r2 == "second")
    }

    // MARK: - VoiceServiceSTTProvider request construction

    @Test("Request has correct URL")
    func requestURL() throws {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "key123")
        let request = try provider.buildRequest(audio: Data([0]))
        #expect(request.url?.absoluteString == "https://example.com/transcribe")
    }

    @Test("Request URL trims trailing slash from base URL")
    func requestURLTrailingSlash() throws {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com/", apiKey: "key123")
        let request = try provider.buildRequest(audio: Data([0]))
        #expect(request.url?.absoluteString == "https://example.com/transcribe")
    }

    @Test("Request is a POST")
    func requestMethod() throws {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(audio: Data([0]))
        #expect(request.httpMethod == "POST")
    }

    @Test("Request has multipart content type with boundary")
    func requestContentType() throws {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(audio: Data([0]))
        let ct = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(ct.hasPrefix("multipart/form-data; boundary="))
    }

    @Test("Request has bearer auth header")
    func requestAuth() throws {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "secret-key")
        let request = try provider.buildRequest(audio: Data([0]))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
    }

    @Test("Request body contains audio data")
    func requestBodyContainsAudio() throws {
        let audio = Data("test-audio-bytes".utf8)
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(audio: audio)
        let body = request.httpBody ?? Data()
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyStr.contains("recording.wav"))
        #expect(bodyStr.contains("audio/wav"))
        #expect(bodyStr.contains("whisper-1"))
        #expect(body.count > audio.count)
    }

    @Test("Request body has correct multipart structure")
    func requestBodyStructure() throws {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "k")
        let request = try provider.buildRequest(audio: Data([42]))
        let body = request.httpBody ?? Data()
        let bodyStr = String(data: body, encoding: .utf8) ?? ""

        // Should have file field and model field
        #expect(bodyStr.contains("name=\"file\""))
        #expect(bodyStr.contains("name=\"model\""))
        // Should end with closing boundary
        #expect(bodyStr.contains("--"))
    }

    @Test("Empty audio throws emptyAudio error")
    func emptyAudioThrows() async {
        let provider = VoiceServiceSTTProvider(
            baseURL: "https://example.com", apiKey: "k")

        do {
            _ = try await provider.transcribe(audio: Data())
            Issue.record("Expected emptyAudio error")
        } catch let error as STTError {
            #expect(error == .emptyAudio)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    // MARK: - STTError

    @Test("STTError cases are equatable")
    func errorEquatable() {
        #expect(STTError.emptyAudio == STTError.emptyAudio)
        #expect(STTError.authenticationFailed == STTError.authenticationFailed)
        #expect(STTError.invalidResponse == STTError.invalidResponse)
        #expect(STTError.transcriptionFailed(statusCode: 500, message: "err")
                == STTError.transcriptionFailed(statusCode: 500, message: "err"))
        #expect(STTError.networkError("timeout") == STTError.networkError("timeout"))
        #expect(STTError.emptyAudio != STTError.authenticationFailed)
    }

    // MARK: - ServiceConfig

    @Test("ServiceConfig has default values")
    func serviceConfigDefaults() {
        // These test that the properties exist and return strings.
        // Actual values depend on env vars, so just test non-crash.
        let url = ServiceConfig.baseURL
        #expect(!url.isEmpty)
        // apiKey may be empty if env var not set, which is fine
        _ = ServiceConfig.apiKey
    }
}
