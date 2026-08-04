import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

/// Thread-safe counter for the stop-read-session seam.
final class ReadSessionStopCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.withLock { _count } }

    func increment() {
        lock.withLock { _count += 1 }
    }
}

@Suite("Conversation call coordinator")
struct ConversationCallCoordinatorTests {

    private struct Harness {
        let coordinator: ConversationCallCoordinator
        let resolver: StubAgentSessionResolver
        let pipeline: MockPipelineProvider
        let hub: TurnSignalHub
        let observer: MockInjectionObserver
        let commandGate: MockCallCommandGate
        let submitter: MockTurnSubmitter
        let watcher: MockResponseWatcher
        let cues: MockCallCuePlayer
        let synthesizer: MockSpeechSynthesizer

        /// Publish a signal for the most recently activated capture
        /// session.
        func publish(_ signal: TurnSignal) {
            guard let sessionID = pipeline.activatedSessionIDs.last else {
                return
            }
            hub.publish(signal, for: sessionID)
        }
    }

    private func agentSession() -> ResolvedAgentSession {
        ResolvedAgentSession(
            agentName: "claude",
            workingDirectory: "/tmp/project",
            ttyDevice: 5)
    }

    private func makeHarness(
        session: ResolvedAgentSession?,
        injectedText: String? = "Fix the failing resampler test.",
        dictationActive: Bool = false,
        readSessionStops: ReadSessionStopCounter = ReadSessionStopCounter()
    ) -> Harness {
        let resolver = StubAgentSessionResolver(session: session)
        let pipeline = MockPipelineProvider()
        let hub = TurnSignalHub()
        let observer = MockInjectionObserver(text: injectedText)
        let commandGate = MockCallCommandGate()
        let submitter = MockTurnSubmitter()
        let watcher = MockResponseWatcher()
        let cues = MockCallCuePlayer()
        let synthesizer = MockSpeechSynthesizer()
        let coordinator = ConversationCallCoordinator(
            contextProvider: MockAppContextProvider(),
            sessionResolver: resolver,
            pipeline: pipeline,
            signalHub: hub,
            injectionObserver: observer,
            commandGate: commandGate,
            submitter: submitter,
            watcher: watcher,
            cuePlayer: cues,
            synthesizer: synthesizer,
            isDictationActive: { dictationActive },
            stopReadSession: { readSessionStops.increment() })
        return Harness(
            coordinator: coordinator,
            resolver: resolver,
            pipeline: pipeline,
            hub: hub,
            observer: observer,
            commandGate: commandGate,
            submitter: submitter,
            watcher: watcher,
            cues: cues,
            synthesizer: synthesizer)
    }

    /// Wait until the coordinator publishes the target state.
    private func waitForState(
        _ coordinator: ConversationCallCoordinator,
        _ target: ConversationCallState
    ) async {
        let stream = await coordinator.stateStream
        for await state in stream where state == target { return }
    }

    /// Poll until the condition holds; return the final evaluation.
    @discardableResult
    private func eventually(
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    /// A short settle for asserting that something did not happen.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Call lifecycle

    @Test("The shortcut starts a call when an agent session is reachable")
    func startsCallWhenAgentSessionReachable() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(harness.pipeline.activatedSessionIDs.count == 1)
        #expect(harness.pipeline.state == .recording)
    }

    @Test("No call starts without a reachable agent session")
    func doesNotStartCallWithoutAgentSession() async {
        let harness = makeHarness(session: nil)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        #expect(harness.pipeline.activatedSessionIDs.isEmpty)
    }

    @Test("A press with no agent session shows guidance and starts no call")
    func showsGuidanceWithoutAgentSession() async {
        let harness = makeHarness(session: nil)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .noAgent)

        await harness.coordinator.dismissGuidance()
        let dismissed = await harness.coordinator.stateStream.first { _ in
            true
        }
        #expect(dismissed == .idle)
    }

    @Test("Starting a call stops an active read session first")
    func startingCallStopsActiveReadSession() async {
        let stops = ReadSessionStopCounter()
        let harness = makeHarness(
            session: agentSession(),
            readSessionStops: stops)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(stops.count == 1)
    }

    @Test("The call reports itself active from start to hangup")
    func isCallActiveReflectsCall() async {
        let harness = makeHarness(session: agentSession())

        #expect(await harness.coordinator.isCallActive == false)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        #expect(await harness.coordinator.isCallActive == true)

        await harness.coordinator.hangUp()
        #expect(await harness.coordinator.isCallActive == false)
    }

    @Test("The call publishes its phases on the state stream")
    func publishesListeningWaitingSpeakingPhases() async {
        let harness = makeHarness(session: agentSession())

        let stream = await harness.coordinator.stateStream
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .idle)

        await harness.coordinator.toggle()
        #expect(await iterator.next() == .listening)

        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        #expect(await iterator.next() == .waiting)

        await eventually { harness.watcher.armed.count == 1 }
        harness.watcher.emit(.response(markdown: "It works."))
        #expect(await iterator.next() == .speaking)
        #expect(await iterator.next() == .listening)

        await harness.coordinator.hangUp()
        #expect(await iterator.next() == .idle)
    }

    @Test("Escape hangs up: capture stops and the state returns to idle")
    func escapeHangsUp() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        await harness.coordinator.hangUp()
        await harness.coordinator.waitForCall()

        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
        #expect(harness.pipeline.state == .idle)
        #expect(harness.watcher.cancelCount == 1)
        #expect(harness.synthesizer.stopCount == 1)
    }

    @Test("A second shortcut press hangs up, identically to Escape")
    func secondShortcutPressHangsUp() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
        #expect(harness.pipeline.state == .idle)
    }

    @Test("Hangup restores the prior input mode: dictation can start again")
    func hangupRestoresPriorInputMode() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        await harness.coordinator.hangUp()
        await harness.coordinator.waitForCall()

        // The pipeline is idle again, so an ordinary dictation press is
        // admitted exactly as before the call.
        let dictationSession = await harness.pipeline.activate()
        #expect(dictationSession != nil)
    }

    @Test("The call shortcut is ignored while dictation is recording")
    func ignoresCallShortcutWhileDictationRecording() async {
        let harness = makeHarness(
            session: agentSession(),
            dictationActive: true)

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        #expect(harness.pipeline.activatedSessionIDs.isEmpty)
    }

    @Test("A hangup that races activation cancels the accepted capture")
    func hangupRacingActivationCancelsCapture() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await harness.coordinator.hangUp()
        await harness.coordinator.waitForCall()

        // Whether or not activation won the race, no capture survives.
        #expect(
            harness.pipeline.cancelledSessionIDs
                == harness.pipeline.activatedSessionIDs)
        #expect(harness.pipeline.state == .idle)
    }

    @Test("A failed pipeline activation ends the call in idle")
    func failedActivationEndsCall() async {
        let harness = makeHarness(session: agentSession())
        harness.pipeline.nextActivateFails = true

        await harness.coordinator.toggle()
        await harness.coordinator.waitForCall()

        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .idle)
    }

    // MARK: - Turn loop

    @Test("The call captures speech with no key held")
    func capturesSpeechWithoutKeyHeld() async {
        let harness = makeHarness(session: agentSession())

        // The coordinator has no hotkey seam at all; toggling alone
        // opens capture and holds it open.
        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        #expect(harness.pipeline.state == .recording)
    }

    @Test("Transcribed speech followed by the pause sends the turn")
    func sendPauseInjectsTranscribedTurn() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        let captureSession = harness.pipeline.activatedSessionIDs.first

        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.pipeline.completedSessionIDs.first == captureSession)
    }

    @Test("An agent target is submitted after injection")
    func submitsOnlyForAgentTargets() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.submitter.submitCount == 1)
    }

    @Test("A non-agent target gets plain dictation and the call relistens")
    func nonAgentTargetIsNotSubmitted() async {
        let harness = makeHarness(session: agentSession())
        // The start gate resolves an agent; the send-time resolution
        // finds none — the user focused another app mid-call.
        harness.resolver.enqueue(agentSession())
        harness.resolver.enqueue(nil)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)

        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        #expect(harness.submitter.submitCount == 0)
        #expect(harness.watcher.armed.isEmpty)
        #expect(harness.pipeline.completedSessionIDs.count == 1)
    }

    @Test("A sent agent turn arms the response watch on the injected text")
    func armsWatchReplacingEarlierWatch() async {
        let harness = makeHarness(
            session: agentSession(),
            injectedText: "Run the tests again.")

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.watcher.armed.count == 1)
        #expect(harness.watcher.armed.first?.anchor == "Run the tests again.")
        #expect(harness.watcher.armed.first?.session == agentSession())
    }

    @Test("The send cue plays at the moment the turn goes")
    func playsSendCueOnSend() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.cues.sendCueCount == 1)
    }

    @Test("A pause with no transcribed speech sends nothing")
    func emptyTurnSendsNothing() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.pause)
        await settle()

        #expect(harness.pipeline.completedSessionIDs.isEmpty)
        #expect(harness.pipeline.activatedSessionIDs.count == 1)
        #expect(harness.cues.sendCueCount == 0)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .listening)
    }

    @Test("The dictation key sends the turn immediately")
    func dictationKeySendsImmediately() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        await harness.coordinator.sendNow()
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.submitter.submitCount == 1)
    }

    @Test("A pause arriving before its transcript sends on the late text")
    func pauseBeforeTranscriptSendsOnLateTranscript() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.pause)
        harness.publish(.transcribedSpeech)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.completedSessionIDs.count == 1)
    }

    @Test("Resumed speech clears a pending pause instead of sending")
    func audibleSpeechClearsPendingPause() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.pause)
        harness.publish(.audibleSpeech)
        harness.publish(.transcribedSpeech)
        await settle()

        #expect(harness.pipeline.completedSessionIDs.isEmpty)

        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        #expect(harness.pipeline.completedSessionIDs.count == 1)
    }

    // MARK: - Waiting and completion

    @Test("A completed response is spoken after the reply cue, then relisten")
    func speaksReplyAndRelistens() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "All tests pass."))
        await waitForState(harness.coordinator, .listening)

        #expect(harness.cues.replyCueCount == 1)
        #expect(harness.synthesizer.spokenTexts.count == 1)
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("All tests pass")
                == true)
        #expect(harness.pipeline.activatedSessionIDs.count == 2)
    }

    @Test("A tool-only turn plays the done cue and relistens")
    func playsDoneCueOnToolOnlyTurn() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.toolOnly)
        await waitForState(harness.coordinator, .listening)

        #expect(harness.cues.doneCueCount == 1)
        #expect(harness.synthesizer.spokenTexts.isEmpty)
        #expect(harness.pipeline.activatedSessionIDs.count == 2)
    }

    @Test("An interim narration reopens the mic over the armed watch")
    func narratesInterimAndReopensMic() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(
            .interimMessage(markdown: "Checking the resampler."))
        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        await waitForState(harness.coordinator, .listening)

        #expect(harness.pipeline.activatedSessionIDs.count == 2)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("An unused open mic closes on the pause and resumes waiting")
    func emptyOpenMicPauseReturnsToWaiting() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "Working on it."))
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }
        let openMicSession = harness.pipeline.activatedSessionIDs.last

        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.cancelledSessionIDs == [openMicSession])
        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("Speech into the reopened mic sends and re-arms the watch")
    func spokenOpenMicTurnSendsAndRearms() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "Working on it."))
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await eventually { harness.watcher.armed.count == 2 }

        #expect(harness.pipeline.completedSessionIDs.count == 2)
        #expect(harness.submitter.submitCount == 2)
    }

    @Test("Interim messages arriving at the reopened mic are dropped")
    func dropsInterimsArrivingDuringOpenMic() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "First update."))
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // Stale progress arrives while the mic is open; the empty
        // pause closes the mic and the message drops.
        harness.watcher.emit(.interimMessage(markdown: "Stale progress."))
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await settle()
        #expect(harness.synthesizer.spokenTexts.count == 1)

        harness.watcher.emit(.response(markdown: "Fresh answer."))
        await eventually { harness.synthesizer.spokenTexts.count == 2 }
    }

    @Test("Completion arriving at the reopened mic resolves the watch")
    func completionDuringOpenMicResolvesWatch() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.interimMessage(markdown: "The answer."))
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The turn completes while the reopened mic hears nothing.
        // The empty pause closes the mic, and the queued completion —
        // its text already narrated — resolves into a full relisten.
        harness.watcher.emit(.completed(markdown: "The answer."))
        harness.publish(.pause)

        await eventually {
            harness.pipeline.activatedSessionIDs.count == 3
        }
        #expect(harness.synthesizer.spokenTexts.count == 1)
        #expect(harness.cues.doneCueCount == 0)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("A response whose narration was dropped speaks at completion")
    func completedAfterDroppedNarrationSpeaks() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        // Barge in; the narration arrives while the mic is open and
        // is dropped.
        await harness.coordinator.dictationKeyPressed()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }
        harness.watcher.emit(.interimMessage(markdown: "The answer."))
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        // The completed response was never actually played here, so
        // completion speaks it.
        harness.watcher.emit(.completed(markdown: "The answer."))
        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("The answer")
                == true)
    }

    @Test("The call waits as long as the watch stays silent")
    func waitingPersistsWithoutEvent() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await settle()

        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .waiting)
        #expect(harness.pipeline.activatedSessionIDs.count == 1)
    }

    // MARK: - Speaking and barge-in

    @Test("The microphone stays closed while call speech plays")
    func keepsMicClosedWhileSpeaking() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await harness.synthesizer.waitUntilSpeaking()

        // The reply is playing and no capture session is open.
        #expect(harness.pipeline.state == .idle)

        harness.synthesizer.stopSpeaking()
        await waitForState(harness.coordinator, .listening)
        #expect(harness.pipeline.state == .recording)
    }

    @Test("The dictation key stops speech before the barge-in mic opens")
    func bargeInStopsSpeechBeforeCapture() async {
        let harness = makeHarness(session: agentSession())
        harness.synthesizer.blocksUntilStopped = true

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        harness.watcher.emit(.response(markdown: "Speaking now."))
        await harness.synthesizer.waitUntilSpeaking()

        await harness.coordinator.dictationKeyPressed()

        #expect(harness.synthesizer.stopCount == 1)
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .listening)
    }

    @Test("No call speech starts while the barge-in mic is open")
    func suppressesSpeechDuringBargeIn() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        await harness.coordinator.dictationKeyPressed()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        harness.watcher.emit(.response(markdown: "Held back."))
        await settle()

        #expect(harness.synthesizer.spokenTexts.isEmpty)
    }

    @Test("Messages arriving during a barge-in are dropped from narration")
    func dropsMessagesArrivingDuringBargeIn() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        await harness.coordinator.dictationKeyPressed()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }
        harness.watcher.emit(.interimMessage(markdown: "Stale progress."))

        // The empty pause ends the barge-in; the stale message drops.
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)
        await settle()
        #expect(harness.synthesizer.spokenTexts.isEmpty)

        // Fresh events after the barge-in still speak.
        harness.watcher.emit(.response(markdown: "Fresh answer."))
        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains("Fresh answer")
                == true)
    }

    @Test("A response arriving during an empty barge-in still speaks")
    func responseDuringEmptyBargeInSpeaks() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        await harness.coordinator.dictationKeyPressed()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        // The final response lands while the barge-in mic is open.
        // The "never mind" never redirected the agent, so the answer
        // is spoken once the mic closes.
        harness.watcher.emit(.response(markdown: "The final answer."))
        harness.publish(.pause)

        await eventually { harness.synthesizer.spokenTexts.count == 1 }
        #expect(
            harness.synthesizer.spokenTexts.first?.contains(
                "The final answer") == true)
    }

    @Test("An empty barge-in closes the mic and returns to waiting")
    func emptyBargeInReturnsToWaiting() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        await harness.coordinator.dictationKeyPressed()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }
        let bargeInSession = harness.pipeline.activatedSessionIDs.last

        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        #expect(harness.pipeline.cancelledSessionIDs == [bargeInSession])
        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.watcher.armed.count == 1)
    }

    @Test("A spoken barge-in turn sends and re-arms the watch")
    func spokenBargeInSendsAndRearms() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await waitForState(harness.coordinator, .waiting)

        await harness.coordinator.dictationKeyPressed()
        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await eventually { harness.watcher.armed.count == 2 }

        #expect(harness.pipeline.completedSessionIDs.count == 2)
        #expect(harness.submitter.submitCount == 2)
    }

    // MARK: - Spoken meta-commands

    @Test("A spoken hang-up ends the call like Escape")
    func spokenHangUpEndsCall() async {
        let harness = makeHarness(session: agentSession())

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)

        // The gate held the utterance back from injection: nothing
        // was recorded, and the command is pending after completion.
        harness.commandGate.pendingCommand = .hangUp
        harness.observer.stubbedText = nil
        harness.publish(.transcribedSpeech)
        harness.publish(.pause)
        await harness.coordinator.waitForCall()

        #expect(await harness.coordinator.isCallActive == false)
        #expect(harness.commandGate.resetCount == 1)
        #expect(harness.submitter.submitCount == 0)
        #expect(harness.watcher.armed.isEmpty)
        let state = await harness.coordinator.stateStream.first { _ in true }
        #expect(state == .idle)
    }

    @Test("A force-send with no speech injects nothing and relistens")
    func forceSendWithoutSpeechKeepsListening() async {
        let harness = makeHarness(
            session: agentSession(),
            injectedText: nil)

        await harness.coordinator.toggle()
        await waitForState(harness.coordinator, .listening)
        await harness.coordinator.sendNow()

        await eventually {
            harness.pipeline.activatedSessionIDs.count == 2
        }

        #expect(harness.pipeline.completedSessionIDs.count == 1)
        #expect(harness.submitter.submitCount == 0)
        #expect(harness.cues.sendCueCount == 0)
    }
}
