import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Injection recorder")
struct InjectionRecorderTests {

    @Test("A successful injection is recorded and forwarded")
    func successfulInjectionIsRecorded() async throws {
        let wrapped = MockTextInjector()
        let recorder = InjectionRecorder(wrapping: wrapped)

        try await recorder.inject(text: "Hello.", into: .stub)

        #expect(wrapped.lastInjectedText == "Hello.")
        #expect(await recorder.lastInjectedText() == "Hello.")
    }

    @Test("A failed injection records nothing")
    func failedInjectionRecordsNothing() async {
        let wrapped = MockTextInjector()
        wrapped.stubbedError = CancellationError()
        let recorder = InjectionRecorder(wrapping: wrapped)

        _ = try? await recorder.inject(text: "Hello.", into: .stub)

        #expect(await recorder.lastInjectedText() == nil)
    }

    @Test("Reset forgets the recorded injection")
    func resetForgetsRecord() async throws {
        let wrapped = MockTextInjector()
        let recorder = InjectionRecorder(wrapping: wrapped)

        try await recorder.inject(text: "Hello.", into: .stub)
        await recorder.reset()

        #expect(await recorder.lastInjectedText() == nil)
    }
}
