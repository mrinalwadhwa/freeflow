import Testing

@testable import UnrambleKit

@Suite("Cohere rolling recognition session")
struct CohereRollingRecognitionSessionTests {
    @Test("Thirty-second windows advance by twenty-five seconds")
    func rollingWindowAndStablePrefix() throws {
        let recorder = WindowRecorder(outputs: [
            Self.words(1...60),
            Self.words(51...110),
        ])
        let session = CohereRollingRecognitionSession {
            try recorder.transcribe($0)
        }

        try session.feed(Self.silence(seconds: 29))
        #expect(recorder.sampleCounts.isEmpty)
        #expect(session.transcript().isEmpty)

        try session.feed(Self.silence(seconds: 1))
        #expect(recorder.sampleCounts == [30 * 16_000])
        #expect(session.transcript().isEmpty)

        try session.feed(Self.silence(seconds: 25))
        #expect(recorder.sampleCounts == [30 * 16_000, 30 * 16_000])
        let secondPublished = session.transcript()
        #expect(secondPublished == Self.words(1...20))

        let finished = try session.finish()
        #expect(finished == Self.words(1...110))
        #expect(recorder.sampleCounts.count == 2)
        #expect(session.preservesContextAcrossHardPauses)
    }

    @Test("Finish transcribes a short dictation once")
    func shortFinish() throws {
        let recorder = WindowRecorder(outputs: ["short dictation."])
        let session = CohereRollingRecognitionSession {
            try recorder.transcribe($0)
        }

        try session.feed(Self.silence(seconds: 10))
        #expect(session.transcript().isEmpty)
        #expect(try session.finish() == "short dictation.")
        #expect(recorder.sampleCounts == [10 * 16_000])
    }

    @Test("Finish transcribes only a tail containing new audio")
    func finishTail() throws {
        let recorder = WindowRecorder(outputs: [
            Self.words(1...60),
            Self.words(1...68),
        ])
        let session = CohereRollingRecognitionSession {
            try recorder.transcribe($0)
        }

        try session.feed(Self.silence(seconds: 30))
        try session.feed(Self.silence(seconds: 3))
        _ = try session.finish()

        #expect(recorder.sampleCounts == [30 * 16_000, 33 * 16_000])
    }

    private static func silence(seconds: Int) -> [Float] {
        [Float](repeating: 0, count: seconds * 16_000)
    }

    private static func words(_ range: ClosedRange<Int>) -> String {
        range.map { "word\($0)" }.joined(separator: " ")
    }
}

private final class WindowRecorder {
    private var outputs: [String]
    private(set) var sampleCounts: [Int] = []

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func transcribe(_ samples: [Float]) throws -> String {
        sampleCounts.append(samples.count)
        return outputs.removeFirst()
    }
}
