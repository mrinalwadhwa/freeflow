import Foundation
import Testing

@testable import UnrambleKit

@Suite("Turn signal hub")
struct TurnSignalHubTests {

    @Test("A published signal reaches the session's observer")
    func publishedSignalReachesObserver() async {
        let hub = TurnSignalHub()
        let sessionID = DictationSessionID()
        let signals = hub.signals(for: sessionID)

        hub.publish(.pause, for: sessionID)

        var iterator = signals.makeAsyncIterator()
        #expect(await iterator.next() == .pause)
    }

    @Test("Signals for another session are not delivered")
    func otherSessionSignalsAreNotDelivered() async {
        let hub = TurnSignalHub()
        let observed = DictationSessionID()
        let other = DictationSessionID()
        let signals = hub.signals(for: observed)

        hub.publish(.pause, for: other)
        hub.publish(.transcribedSpeech, for: observed)

        var iterator = signals.makeAsyncIterator()
        #expect(await iterator.next() == .transcribedSpeech)
    }

    @Test("Signals published between subscription and reading buffer")
    func signalsBufferFromSubscription() async {
        let hub = TurnSignalHub()
        let sessionID = DictationSessionID()
        let signals = hub.signals(for: sessionID)

        hub.publish(.transcribedSpeech, for: sessionID)
        hub.publish(.pause, for: sessionID)

        var iterator = signals.makeAsyncIterator()
        #expect(await iterator.next() == .transcribedSpeech)
        #expect(await iterator.next() == .pause)
    }

    @Test("Ending a session finishes its observers")
    func endSessionFinishesObservers() async {
        let hub = TurnSignalHub()
        let sessionID = DictationSessionID()
        let signals = hub.signals(for: sessionID)

        hub.endSession(sessionID)

        var iterator = signals.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("Publishing to a session nobody observes is a no-op")
    func publishWithoutObserversIsNoOp() {
        let hub = TurnSignalHub()
        hub.publish(.pause, for: DictationSessionID())
    }
}
