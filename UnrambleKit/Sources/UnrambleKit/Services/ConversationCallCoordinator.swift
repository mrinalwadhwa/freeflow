import Foundation

/// Owns the conversation call: an explicit voice session with a
/// coding agent.
///
/// One call exists at a time. The call shortcut toggles it — a press
/// while a call is active hangs up, identically to Escape. A call
/// starts only when the frontmost window hosts a coding-agent session
/// and dictation is not recording, so the two features never contend
/// for audio. `toggle` claims or releases the call without suspending,
/// so two rapid presses cannot start two calls; the dictation check
/// happens inside the claimed call task.
///
/// While the call listens, the streaming provider publishes
/// `TurnSignal`s for the capture session. A pause sends the turn only
/// when speech was transcribed — silence and background noise never
/// send — and the dictation key sends immediately. Sending completes
/// the capture session, which injects through the ordinary dictation
/// path; a coding-agent target is then submitted and watched, while
/// any other target keeps plain dictation semantics and the call keeps
/// listening. Whenever a narration finishes, the mic reopens over the
/// still-armed watch so the user can speak the moment the voice stops;
/// an empty pause returns the call to waiting. A turn whose whole
/// utterance is a spoken meta-command — "hang up" — executes against
/// the call itself and is never sent.
public actor ConversationCallCoordinator {

    private enum TurnEnd {
        case send(sawTranscribedSpeech: Bool)

        /// A barge-in turn heard nothing at all; the mic closes and
        /// the call resumes waiting.
        case abandoned

        /// Nobody spoke for the whole idle window; the call ends
        /// rather than holding an open microphone forever.
        case idleTimedOut
    }

    /// How one capture turn resolved.
    private enum TurnOutcome {
        case ended
        case listeningContinues
        case watchArmed(AsyncStream<ResponseWatchEvent>)
    }

    /// How the consumption of one armed watch resolved.
    private enum WatchOutcome {
        case relisten
        case ended
        case rearmed(AsyncStream<ResponseWatchEvent>)
    }

    /// How one open-mic turn hosted over an armed watch resolved.
    private enum OpenMicOutcome {
        case resolved(WatchOutcome)

        /// The turn ended without superseding the watch — an empty
        /// pause or a turn that stayed plain dictation.
        case resumeWaiting
    }

    private enum WaitEvent {
        case watch(ResponseWatchEvent, arrivedAt: Date)
        case bargeIn
    }

    private enum TurnEvent: Sendable {
        case signal(TurnSignal)
        case force
        case idleTimeout
    }

    /// The subscription backing one turn's endpoint wait. Created
    /// before the listening state becomes visible, so no signal
    /// published against the fresh capture session can be missed.
    private struct TurnWait {
        let events: AsyncStream<TurnEvent>
        let continuation: AsyncStream<TurnEvent>.Continuation
        let forwarder: Task<Void, Never>
        let idleTimer: Task<Void, Never>?
    }

    private let contextProvider: any AppContextProviding
    private let sessionResolver: any AgentSessionResolving
    private let pipeline: any PipelineProviding
    private let signalHub: TurnSignalHub
    private let injectionObserver: any InjectionObserving
    private let commandGate: any CallCommandGating
    private let submitter: any TurnSubmitting
    private let watcher: any ResponseWatching
    private let cuePlayer: any CallCuePlaying
    private let scriptBuilder: SpeechScriptBuilder
    private let synthesizer: any SpeechSynthesizing
    private let isDictationActive: @Sendable () async -> Bool
    private let stopReadSession: @Sendable () async -> Void

    /// How long full listening may go without any transcribed speech
    /// before the call ends itself. An unattended open microphone is
    /// a privacy and cost hazard; open-mic turns over a watch close
    /// themselves on the pause and are not subject to this window.
    private let idleTimeout: TimeInterval

    private var callTask: Task<Void, Never>?

    /// The most recently ended call's task, retained so `waitForCall`
    /// can drain an abandoned call deterministically.
    private var stoppedCallTask: Task<Void, Never>?

    /// Pipeline and watch teardown issued by hangup, retained for the
    /// same deterministic drain.
    private var teardownTask: Task<Void, Never>?

    /// Incremented on every call start and hangup. A finishing call
    /// commits its teardown only when its generation is still current,
    /// so a stale task cannot clear a newer call's handle or state.
    private var callGeneration = 0

    /// The dictation session that captures the call's audio while the
    /// call is listening.
    private var captureSessionID: DictationSessionID?

    /// Resumes the in-flight turn wait when the user force-sends.
    private var forceSendTrigger: (@Sendable () -> Void)?

    /// Delivers a barge-in request into the in-flight watch wait.
    private var bargeInTrigger: (@Sendable () -> Void)?

    /// Set while a barge-in request is on its way to the watch wait,
    /// so a speech handler that resumes early does not relisten past
    /// the pending barge-in.
    private var bargeInRequested = false

    private var state: ConversationCallState = .idle
    private var continuations:
        [UUID: AsyncStream<ConversationCallState>.Continuation] = [:]

    /// The agent session whose response the call is watching or
    /// speaking, for presentation. Set when a turn arms the watch and
    /// cleared when the call ends.
    public private(set) var lastResolvedAgent: ResolvedAgentSession?

    public init(
        contextProvider: any AppContextProviding,
        sessionResolver: any AgentSessionResolving,
        pipeline: any PipelineProviding,
        signalHub: TurnSignalHub,
        injectionObserver: any InjectionObserving,
        commandGate: any CallCommandGating,
        submitter: any TurnSubmitting,
        watcher: any ResponseWatching,
        cuePlayer: any CallCuePlaying,
        scriptBuilder: SpeechScriptBuilder = SpeechScriptBuilder(),
        synthesizer: any SpeechSynthesizing,
        isDictationActive: @escaping @Sendable () async -> Bool,
        stopReadSession: @escaping @Sendable () async -> Void = {},
        idleTimeout: TimeInterval = 180
    ) {
        self.contextProvider = contextProvider
        self.sessionResolver = sessionResolver
        self.pipeline = pipeline
        self.signalHub = signalHub
        self.injectionObserver = injectionObserver
        self.commandGate = commandGate
        self.submitter = submitter
        self.watcher = watcher
        self.cuePlayer = cuePlayer
        self.scriptBuilder = scriptBuilder
        self.synthesizer = synthesizer
        self.isDictationActive = isDictationActive
        self.stopReadSession = stopReadSession
        self.idleTimeout = idleTimeout
    }

    /// Whether a call is active in any phase. The app ignores the
    /// hands-free toggle while this is true.
    public var isCallActive: Bool {
        callTask != nil
    }

    // MARK: - Observation

    /// Stream call state changes. The current state is emitted
    /// immediately upon subscription, followed by every subsequent
    /// change.
    public var stateStream: AsyncStream<ConversationCallState> {
        let currentState = state
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(currentState)
            self.continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func transition(to newState: ConversationCallState) {
        guard state != newState else { return }
        Log.debug(
            "[Call] \(state) → \(newState)"
                + " at \(CFAbsoluteTimeGetCurrent())")
        state = newState
        for (_, continuation) in continuations {
            continuation.yield(newState)
        }
    }

    private func transitionIfCurrent(
        generation: Int,
        to newState: ConversationCallState
    ) {
        guard generation == callGeneration else { return }
        transition(to: newState)
    }

    // MARK: - Call control

    /// Start a call, or hang up the one in progress.
    public func toggle() {
        if callTask != nil {
            hangUp()
            return
        }
        startCall()
    }

    /// End the call immediately: speech stops, capture stops, the
    /// armed watch is cancelled, and the state returns to idle. Safe
    /// to call at any time; Escape and a second shortcut press both
    /// land here.
    public func hangUp() {
        guard let task = callTask else { return }
        callTask = nil
        stoppedCallTask = task
        callGeneration += 1
        bargeInRequested = false
        lastResolvedAgent = nil
        task.cancel()
        synthesizer.stopSpeaking()
        let sessionID = captureSessionID
        captureSessionID = nil
        let pipeline = pipeline
        let watcher = watcher
        teardownTask = Task {
            if let sessionID {
                await pipeline.cancel(sessionID: sessionID)
            }
            await watcher.cancelWatch()
        }
        transition(to: .idle)
    }

    /// Send the turn being listened to immediately, without waiting
    /// out the send pause. The dictation key triggers this while the
    /// call listens.
    public func sendNow() {
        forceSendTrigger?()
    }

    /// The dictation key during a call: send immediately while
    /// listening, barge in while waiting or speaking.
    public func dictationKeyPressed() {
        switch state {
        case .listening:
            sendNow()
        case .waiting, .speaking:
            bargeIn()
        case .idle, .noAgent:
            break
        }
    }

    /// Stop call speech and open the mic for a barge-in turn. Speech
    /// stops here, before capture begins, so the mic never hears the
    /// synthesized voice. The request flag is raised only when a watch
    /// wait exists to consume it; a press in the gap between watches
    /// stops speech and nothing more.
    public func bargeIn() {
        guard callTask != nil else { return }
        synthesizer.stopSpeaking()
        guard let trigger = bargeInTrigger else { return }
        bargeInRequested = true
        trigger()
    }

    /// Wait for the in-flight or most recently ended call work to
    /// finish.
    func waitForCall() async {
        await callTask?.value
        await stoppedCallTask?.value
        await teardownTask?.value
    }

    private func startCall() {
        callGeneration += 1
        let generation = callGeneration
        callTask = Task { [weak self] in
            guard let self else { return }
            await self.runCall(generation: generation)
        }
    }

    private func runCall(generation: Int) async {
        // Ignored while dictation is recording so the call never takes
        // the microphone from the user's own capture (checked here,
        // inside the claimed call, so the claim itself never suspends).
        guard await !isDictationActive() else {
            finishCall(generation: generation)
            return
        }

        // The call takes over the speech channel from any read session.
        await stopReadSession()
        guard !Task.isCancelled else { return }

        let context = await contextProvider.readContext()
        guard !Task.isCancelled else { return }

        guard await sessionResolver.resolveSession(for: context) != nil else {
            finishCall(generation: generation, in: .noAgent)
            return
        }
        guard !Task.isCancelled else { return }

        await runTurnLoop(generation: generation)
    }

    /// Dismiss the no-agent guidance. Ignored while a call is active
    /// so a delayed dismissal can never disturb a newer call's state.
    public func dismissGuidance() {
        guard callTask == nil, state == .noAgent else { return }
        transition(to: .idle)
    }

    /// Listen, send on the endpoint, and keep listening after turns
    /// that stayed plain dictation. A submitted agent turn hands the
    /// call to the watch loop, which relistens after the response and
    /// hosts open-mic turns. The loop leaves through hangup or a
    /// failed activation.
    private func runTurnLoop(generation: Int) async {
        while !Task.isCancelled, generation == callGeneration {
            let outcome = await performTurn(
                generation: generation,
                abandonsOnEmptyPause: false)
            switch outcome {
            case .ended:
                return
            case .listeningContinues:
                continue
            case .watchArmed(var watchEvents):
                watching: while true {
                    let watchOutcome = await waitOutWatch(
                        watchEvents,
                        generation: generation)
                    switch watchOutcome {
                    case .ended:
                        return
                    case .relisten:
                        break watching
                    case .rearmed(let newEvents):
                        watchEvents = newEvents
                    }
                }
            }
        }
    }

    /// One capture turn: listen, endpoint, and deliver.
    private func performTurn(
        generation: Int,
        abandonsOnEmptyPause: Bool
    ) async -> TurnOutcome {
        guard let sessionID = await pipeline.activate(playsCaptureCues: false)
        else {
            // The pipeline refused capture — e.g. a failed dictation
            // session holds admission for an explicit retry. End the
            // call audibly instead of vanishing mid-conversation.
            if generation == callGeneration, !Task.isCancelled {
                cuePlayer.playDoneCue()
            }
            finishCall(generation: generation)
            return .ended
        }

        // Subscribe to the session's signals before listening becomes
        // visible, so no early signal is dropped. Only full listening
        // carries the idle window; open-mic turns close themselves.
        let turnWait = beginTurnWait(
            sessionID: sessionID,
            idleTimeout: abandonsOnEmptyPause ? nil : idleTimeout)

        // A hangup that raced activation must not leak the capture.
        guard adoptCapture(generation: generation, sessionID: sessionID)
        else {
            endTurnWait(turnWait)
            await pipeline.cancel(sessionID: sessionID)
            return .ended
        }

        guard
            let turnEnd = await awaitTurnEnd(
                turnWait,
                abandonsOnEmptyPause: abandonsOnEmptyPause),
            generation == callGeneration, !Task.isCancelled
        else { return .ended }
        Log.debug("[Call] turn end: \(turnEnd)")

        switch turnEnd {
        case .idleTimedOut:
            // Nobody spoke for the whole idle window; end the call
            // audibly instead of holding an open microphone forever.
            if generation == callGeneration, !Task.isCancelled {
                cuePlayer.playDoneCue()
            }
            hangUp()
            return .ended

        case .abandoned:
            clearCapture(generation: generation, sessionID: sessionID)
            await pipeline.cancel(sessionID: sessionID)
            guard generation == callGeneration, !Task.isCancelled else {
                return .ended
            }
            return .listeningContinues

        case .send:
            await injectionObserver.reset()
            await commandGate.reset()
            await pipeline.complete(sessionID: sessionID)
            clearCapture(generation: generation, sessionID: sessionID)
            guard generation == callGeneration, !Task.isCancelled else {
                return .ended
            }

            // A turn whose whole utterance was a meta-command was
            // held back from injection; execute it instead.
            if let command = await commandGate.takePendingCommand() {
                return perform(command)
            }

            // An empty turn injected nothing; keep listening. Noise
            // can endpoint as a sendable turn whose transcript turns
            // out empty, so the send cue waits for delivered text —
            // an honest cue over an early one.
            guard let injected = await injectionObserver.lastInjectedText(),
                !injected.isEmpty
            else { return .listeningContinues }
            cuePlayer.playSendCue()

            let sendContext = await contextProvider.readContext()
            guard generation == callGeneration, !Task.isCancelled else {
                return .ended
            }
            guard
                let target = await sessionResolver.resolveSession(
                    for: sendContext)
            else {
                // The turn went to a non-agent target as plain
                // dictation; the call keeps listening.
                return .listeningContinues
            }
            await submitter.submitTurn()
            lastResolvedAgent = target
            let watchEvents = await watcher.arm(
                session: target, anchor: injected)
            transitionIfCurrent(generation: generation, to: .waiting)
            return .watchArmed(watchEvents)
        }
    }

    /// Execute a spoken meta-command and return how the turn resolved.
    private func perform(_ command: CallMetaCommand) -> TurnOutcome {
        Log.debug("[Call] meta-command: \(command)")
        switch command {
        case .hangUp:
            hangUp()
            return .ended
        }
    }

    /// Consume the armed watch — narrating interim messages, speaking
    /// the response, and hosting open-mic turns: barge-ins, and the
    /// mic reopening whenever a narration finishes. Interim messages
    /// that arrived while a mic was open are dropped as stale
    /// progress — the transcript stays the source of truth — but a
    /// completion always resolves the watch: it is the answer, and
    /// only a send that redirects the agent supersedes it.
    private func waitOutWatch(
        _ events: AsyncStream<ResponseWatchEvent>,
        generation: Int
    ) async -> WatchOutcome {
        let (merged, mergedContinuation) = AsyncStream<WaitEvent>.makeStream()
        let pump = Task {
            for await event in events {
                mergedContinuation.yield(.watch(event, arrivedAt: Date()))
            }
            mergedContinuation.finish()
        }
        bargeInTrigger = { mergedContinuation.yield(.bargeIn) }
        defer {
            bargeInTrigger = nil
            bargeInRequested = false
            pump.cancel()
        }

        var dropBefore: Date?
        var narratedThisWatch: Set<String> = []
        var iterator = merged.makeAsyncIterator()
        while let event = await iterator.next() {
            guard generation == callGeneration, !Task.isCancelled else {
                return .ended
            }
            switch event {
            case .watch(let watchEvent, let arrivedAt):
                if case .interimMessage = watchEvent,
                    let dropBefore, arrivedAt < dropBefore
                { continue }
                switch watchEvent {
                case .interimMessage(let markdown):
                    narratedThisWatch.insert(markdown)
                    transitionIfCurrent(generation: generation, to: .speaking)
                    cuePlayer.playReplyCue()
                    await speak(markdown)
                    guard generation == callGeneration, !Task.isCancelled
                    else { return .ended }
                    guard !bargeInRequested else { continue }
                    // The end of a narration is a natural opening;
                    // reopen the mic while the turn keeps running.
                    switch await hostOpenMicTurn(generation: generation) {
                    case .resolved(let outcome):
                        return outcome
                    case .resumeWaiting:
                        dropBefore = Date()
                        transitionIfCurrent(
                            generation: generation, to: .waiting)
                    }
                case .response(let markdown):
                    transitionIfCurrent(generation: generation, to: .speaking)
                    cuePlayer.playReplyCue()
                    await speak(markdown)
                    guard generation == callGeneration, !Task.isCancelled
                    else { return .ended }
                    guard !bargeInRequested else { continue }
                    return .relisten
                case .completed(let markdown):
                    guard !bargeInRequested else { continue }
                    // The watcher saw its text narrated, but a barge-in
                    // drop may have swallowed that narration here;
                    // speak anything this watch never actually played.
                    if !narratedThisWatch.contains(markdown) {
                        transitionIfCurrent(
                            generation: generation, to: .speaking)
                        cuePlayer.playReplyCue()
                        await speak(markdown)
                        guard generation == callGeneration, !Task.isCancelled
                        else { return .ended }
                    }
                    return .relisten
                case .toolOnly:
                    guard !bargeInRequested else { continue }
                    // No cue: with tool-heavy agents the window
                    // expires constantly, and the pill's return to
                    // listening already shows it. The done cue is
                    // reserved for the call itself ending.
                    return .relisten
                }
            case .bargeIn:
                bargeInRequested = false
                switch await hostOpenMicTurn(generation: generation) {
                case .resolved(let outcome):
                    return outcome
                case .resumeWaiting:
                    dropBefore = Date()
                    transitionIfCurrent(generation: generation, to: .waiting)
                }
            }
        }
        guard generation == callGeneration, !Task.isCancelled else {
            return .ended
        }
        // The watch ended with nothing left to deliver; reopening the
        // mic is the safe continuation.
        return .relisten
    }

    /// Host one open-mic turn over the armed watch: a barge-in, or
    /// the mic reopening after a narration. A send that reaches the
    /// agent supersedes the watch; an empty pause — a "never mind" or
    /// an unused opening — and a turn that stayed plain dictation
    /// both close the mic and resume waiting on the watch.
    private func hostOpenMicTurn(generation: Int) async -> OpenMicOutcome {
        let outcome = await performTurn(
            generation: generation,
            abandonsOnEmptyPause: true)
        switch outcome {
        case .ended:
            return .resolved(.ended)
        case .listeningContinues:
            return .resumeWaiting
        case .watchArmed(let newEvents):
            return .resolved(.rearmed(newEvents))
        }
    }

    private func speak(_ markdown: String) async {
        let content = ReadableContent(
            segments: MarkdownSegmenter.segments(from: markdown))
        Log.debug("[Call] speak begin at \(CFAbsoluteTimeGetCurrent())")
        await synthesizer.speak(scriptBuilder.script(for: content))
        Log.debug("[Call] speak end at \(CFAbsoluteTimeGetCurrent())")
    }

    /// Subscribe to the capture session's signals and install the
    /// force-send trigger. A non-nil idle timeout schedules the
    /// turn's idle deadline; the endpoint ignores it once any speech
    /// was heard.
    private func beginTurnWait(
        sessionID: DictationSessionID,
        idleTimeout: TimeInterval?
    ) -> TurnWait {
        let (events, continuation) = AsyncStream<TurnEvent>.makeStream()
        let signals = signalHub.signals(for: sessionID)
        let forwarder = Task {
            for await signal in signals {
                continuation.yield(.signal(signal))
            }
        }
        forceSendTrigger = { continuation.yield(.force) }
        let idleTimer = idleTimeout.map { timeout in
            Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                continuation.yield(.idleTimeout)
            }
        }
        return TurnWait(
            events: events,
            continuation: continuation,
            forwarder: forwarder,
            idleTimer: idleTimer)
    }

    private func endTurnWait(_ wait: TurnWait) {
        forceSendTrigger = nil
        wait.forwarder.cancel()
        wait.idleTimer?.cancel()
        wait.continuation.finish()
    }

    /// Consume the capture session's turn signals until an endpoint.
    ///
    /// A pause sends only when speech was transcribed. A pause that
    /// arrives before the transcript catches up is held pending: the
    /// late-arriving transcript sends the turn, unless speech audio
    /// resumed first, which re-arms the endpoint. A barge-in turn
    /// abandons on a pause that heard nothing at all — silence means
    /// "never mind", while audible speech waits for its transcript.
    /// Returns nil when the call was hung up mid-listen.
    private func awaitTurnEnd(
        _ wait: TurnWait,
        abandonsOnEmptyPause: Bool
    ) async -> TurnEnd? {
        defer { endTurnWait(wait) }

        var sawTranscribedSpeech = false
        var sawAudibleSpeech = false
        var pendingPause = false
        for await event in wait.events {
            guard !Task.isCancelled else { return nil }
            switch event {
            case .signal(.transcribedSpeech):
                sawTranscribedSpeech = true
                if pendingPause {
                    return .send(sawTranscribedSpeech: true)
                }
            case .signal(.audibleSpeech):
                sawAudibleSpeech = true
                pendingPause = false
            case .signal(.pause):
                if sawTranscribedSpeech {
                    return .send(sawTranscribedSpeech: true)
                }
                if abandonsOnEmptyPause, !sawAudibleSpeech {
                    return .abandoned
                }
                pendingPause = true
            case .force:
                return .send(sawTranscribedSpeech: sawTranscribedSpeech)
            case .idleTimeout:
                // Speech anywhere in the turn means the user is
                // present; the endpoint will come, so the deadline
                // stands down.
                if !sawTranscribedSpeech, !sawAudibleSpeech {
                    return .idleTimedOut
                }
            }
        }
        return nil
    }

    /// Bind the accepted capture session to the still-current call and
    /// enter listening.
    private func adoptCapture(
        generation: Int,
        sessionID: DictationSessionID
    ) -> Bool {
        guard generation == callGeneration else { return false }
        captureSessionID = sessionID
        transition(to: .listening)
        return true
    }

    /// Release a capture session that completion now owns.
    private func clearCapture(
        generation: Int,
        sessionID: DictationSessionID
    ) {
        guard generation == callGeneration, captureSessionID == sessionID
        else { return }
        captureSessionID = nil
    }

    /// End the call without a capture to tear down: the start was
    /// refused or failed before listening began. A refusal with no
    /// reachable agent session ends in the guidance state.
    private func finishCall(
        generation: Int,
        in terminalState: ConversationCallState = .idle
    ) {
        guard generation == callGeneration else { return }
        callTask = nil
        lastResolvedAgent = nil
        transition(to: terminalState)
    }
}
