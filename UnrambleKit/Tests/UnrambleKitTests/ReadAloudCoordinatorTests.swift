import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Read-aloud coordinator")
struct ReadAloudCoordinatorTests {

    private func content(_ text: String) -> ReadableContent {
        ReadableContent(segments: [.init(kind: .prose, text: text)])
    }

    private func makeCoordinator(
        selection: StubContentSource,
        agent: StubContentSource = StubContentSource(),
        synthesizer: MockSpeechSynthesizer = MockSpeechSynthesizer(),
        dictationActive: Bool = false,
        acquisitionTimeout: TimeInterval = 2.0
    ) -> ReadAloudCoordinator {
        ReadAloudCoordinator(
            contextProvider: MockAppContextProvider(),
            sources: [selection, agent],
            synthesizer: synthesizer,
            isDictationActive: { dictationActive },
            acquisitionTimeout: acquisitionTimeout)
    }

    @Test("Toggle speaks the first source's content")
    func toggleSpeaksFirstSource() async {
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: StubContentSource(stubbedContent: content("Selected.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["Selected."])
    }

    @Test("A nil source falls through to the next")
    func nilSourceFallsThrough() async {
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: StubContentSource(stubbedContent: nil),
            agent: StubContentSource(stubbedContent: content("Agent answer.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["Agent answer."])
    }

    @Test("A source with only whitespace content falls through")
    func emptyContentFallsThrough() async {
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: StubContentSource(
                stubbedContent: ReadableContent(segments: [
                    .init(kind: .prose, text: "  \n ")
                ])),
            agent: StubContentSource(stubbedContent: content("Real answer.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["Real answer."])
    }

    @Test("A throwing source falls through to the next")
    func throwingSourceFallsThrough() async {
        let selection = StubContentSource()
        selection.throwsError = true
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: selection,
            agent: StubContentSource(stubbedContent: content("Recovered.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["Recovered."])
    }

    @Test("A source exceeding the acquisition timeout is skipped")
    func timedOutSourceIsSkipped() async {
        let selection = StubContentSource(stubbedContent: content("Slow."))
        selection.blocksUntilCancelled = true
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: selection,
            agent: StubContentSource(stubbedContent: content("Fast.")),
            synthesizer: synthesizer,
            acquisitionTimeout: 0.05)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["Fast."])
    }

    /// Read the coordinator's current state via a fresh stream subscription,
    /// which yields the current state immediately.
    private func currentState(
        of coordinator: ReadAloudCoordinator
    ) async -> ReadAloudState? {
        var iterator = await coordinator.stateStream.makeAsyncIterator()
        return await iterator.next()
    }

    @Test("No content ends the session in the guidance state")
    func noContentEndsSessionInGuidance() async {
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: StubContentSource(),
            synthesizer: synthesizer)

        var observed: [ReadAloudState] = []
        let stream = await coordinator.stateStream
        let observer = Task {
            for await state in stream {
                observed.append(state)
                if Array(observed.suffix(2)) == [.acquiring, .noContent] {
                    break
                }
            }
        }

        await coordinator.toggle()
        await coordinator.waitForSession()
        await observer.value

        #expect(synthesizer.spokenTexts.isEmpty)
        #expect(observed == [.idle, .acquiring, .noContent])
    }

    @Test("Acquisition timing out everywhere ends in the guidance state")
    func timeoutEverywhereEndsInGuidance() async {
        let selection = StubContentSource(stubbedContent: content("Slow."))
        selection.blocksUntilCancelled = true
        let agent = StubContentSource(stubbedContent: content("Also slow."))
        agent.blocksUntilCancelled = true
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: selection,
            agent: agent,
            synthesizer: synthesizer,
            acquisitionTimeout: 0.05)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts.isEmpty)
        #expect(await currentState(of: coordinator) == .noContent)
    }

    @Test("Dismissing guidance returns to idle")
    func dismissGuidanceReturnsToIdle() async {
        let coordinator = makeCoordinator(selection: StubContentSource())

        await coordinator.toggle()
        await coordinator.waitForSession()
        #expect(await currentState(of: coordinator) == .noContent)

        await coordinator.dismissGuidance()
        #expect(await currentState(of: coordinator) == .idle)
    }

    @Test("Dismissing guidance while speaking is ignored")
    func dismissGuidanceWhileSpeakingIsIgnored() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.blocksUntilStopped = true
        let coordinator = makeCoordinator(
            selection: StubContentSource(stubbedContent: content("Long.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await synthesizer.waitUntilSpeaking()
        await coordinator.dismissGuidance()
        #expect(await currentState(of: coordinator) == .speaking)

        await coordinator.stop()
        await coordinator.waitForSession()
    }

    @Test("Dismissing guidance while acquiring is ignored")
    func dismissGuidanceWhileAcquiringIsIgnored() async {
        let selection = StubContentSource(stubbedContent: content("Blocked."))
        selection.blocksUntilCancelled = true
        let coordinator = makeCoordinator(selection: selection)

        await coordinator.toggle()
        await coordinator.dismissGuidance()
        #expect(await currentState(of: coordinator) == .acquiring)

        await coordinator.stop()
        await coordinator.waitForSession()
    }

    @Test("Dictation starting during acquisition prevents speech")
    func dictationDuringAcquisitionPreventsSpeech() async {
        final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int {
                lock.withLock {
                    count += 1
                    return count
                }
            }
        }

        let synthesizer = MockSpeechSynthesizer()
        let counter = CallCounter()
        let coordinator = ReadAloudCoordinator(
            contextProvider: MockAppContextProvider(),
            sources: [StubContentSource(stubbedContent: content("Unspoken."))],
            synthesizer: synthesizer,
            isDictationActive: { counter.next() > 1 })

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts.isEmpty)
        #expect(await currentState(of: coordinator) == .idle)
    }

    @Test("Stop clears lingering guidance")
    func stopClearsLingeringGuidance() async {
        let coordinator = makeCoordinator(selection: StubContentSource())

        await coordinator.toggle()
        await coordinator.waitForSession()
        #expect(await currentState(of: coordinator) == .noContent)

        await coordinator.stop()
        #expect(await currentState(of: coordinator) == .idle)
    }

    @Test("A press during guidance starts a new session")
    func pressDuringGuidanceStartsNewSession() async {
        let selection = StubContentSource()
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: selection,
            synthesizer: synthesizer)

        await coordinator.toggle()
        await coordinator.waitForSession()
        #expect(await currentState(of: coordinator) == .noContent)

        selection.stubbedContent = content("Found this time.")
        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["Found this time."])
        #expect(await currentState(of: coordinator) == .idle)
    }

    @Test("Toggling while speaking stops speech")
    func toggleWhileSpeakingStops() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.blocksUntilStopped = true
        let coordinator = makeCoordinator(
            selection: StubContentSource(stubbedContent: content("Long text.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await synthesizer.waitUntilSpeaking()
        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.stopCount == 1)
    }

    @Test("Stop during acquisition abandons the session unspoken")
    func stopDuringAcquisitionAbandons() async {
        let selection = StubContentSource(stubbedContent: content("Blocked."))
        selection.blocksUntilCancelled = true
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: selection,
            agent: StubContentSource(stubbedContent: content("Also unspoken.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await coordinator.stop()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts.isEmpty)
    }

    @Test("A press during dictation is ignored")
    func pressDuringDictationIsIgnored() async {
        let selection = StubContentSource(stubbedContent: content("Ignored."))
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = makeCoordinator(
            selection: selection,
            synthesizer: synthesizer,
            dictationActive: true)

        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts.isEmpty)
        #expect(selection.readCount == 0)
    }

    @Test("Stop lets a new session start afterwards")
    func stopAllowsNewSession() async {
        let synthesizer = MockSpeechSynthesizer()
        synthesizer.blocksUntilStopped = true
        let coordinator = makeCoordinator(
            selection: StubContentSource(stubbedContent: content("First.")),
            synthesizer: synthesizer)

        await coordinator.toggle()
        await synthesizer.waitUntilSpeaking()
        await coordinator.stop()
        await coordinator.waitForSession()

        synthesizer.blocksUntilStopped = false
        await coordinator.toggle()
        await coordinator.waitForSession()

        #expect(synthesizer.spokenTexts == ["First.", "First."])
    }
}
