import Foundation
import Testing

@testable import FreeFlowKit

// MARK: - Safe continuation tests

@Suite("SafeRecognitionContinuation")
struct SafeRecognitionContinuationTests {

    @Test("Returns result when callback fires once with final result")
    func singleFinalResult() async throws {
        let text = try await SafeRecognitionContinuation.run { handler in
            handler("Hello world", nil)
        }
        #expect(text == "Hello world")
    }

    @Test("Throws error when callback fires once with error")
    func singleError() async {
        do {
            _ = try await SafeRecognitionContinuation.run { handler in
                handler(nil, DictationError.networkError("fail"))
            }
            Issue.record("Expected error")
        } catch {
            #expect(error is DictationError)
        }
    }

    @Test("Ignores second callback after final result delivered")
    func doubleFireResultThenError() async throws {
        let text = try await SafeRecognitionContinuation.run { handler in
            // First: deliver final result.
            handler("Hello world", nil)
            // Second: deliver error (should be ignored, not crash).
            handler(nil, DictationError.networkError("late error"))
        }
        #expect(text == "Hello world")
    }

    @Test("Ignores second callback after error delivered")
    func doubleFireErrorThenResult() async {
        do {
            _ = try await SafeRecognitionContinuation.run { handler in
                // First: deliver error.
                handler(nil, DictationError.networkError("fail"))
                // Second: deliver result (should be ignored).
                handler("Late result", nil)
            }
            Issue.record("Expected error")
        } catch {
            #expect(error is DictationError)
        }
    }

    @Test("Skips non-final callbacks before delivering final result")
    func partialThenFinal() async throws {
        let text = try await SafeRecognitionContinuation.run { handler in
            // Partial: nil text, no error (skip).
            handler(nil, nil)
            // Final: deliver result.
            handler("Final text", nil)
        }
        #expect(text == "Final text")
    }
}

// MARK: - Dictation error tests

@Suite("Dictation error")
struct DictationErrorTests {

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
}
