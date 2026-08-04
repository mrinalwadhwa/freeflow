import Foundation

@testable import UnrambleKit

/// A mock `ResponseWatching` whose watch events tests deliver by hand.
public final class MockResponseWatcher: ResponseWatching, @unchecked Sendable {

    private let lock = NSLock()

    /// Sessions and anchors passed to `arm`, in order.
    public var armed: [(session: ResolvedAgentSession, anchor: String)] {
        lock.withLock { _armed }
    }
    private var _armed: [(session: ResolvedAgentSession, anchor: String)] = []

    /// Number of times `cancelWatch()` was called.
    public var cancelCount: Int {
        lock.withLock { _cancelCount }
    }
    private var _cancelCount = 0

    private var continuation: AsyncStream<ResponseWatchEvent>.Continuation?

    public init() {}

    public func arm(
        session: ResolvedAgentSession,
        anchor: String
    ) async -> AsyncStream<ResponseWatchEvent> {
        let (stream, continuation) =
            AsyncStream<ResponseWatchEvent>.makeStream()
        lock.withLock {
            _armed.append((session, anchor))
            self.continuation?.finish()
            self.continuation = continuation
        }
        return stream
    }

    public func cancelWatch() async {
        lock.withLock {
            _cancelCount += 1
            continuation?.finish()
            continuation = nil
        }
    }

    /// Deliver an event on the current watch.
    public func emit(_ event: ResponseWatchEvent) {
        lock.withLock { _ = continuation?.yield(event) }
    }

    /// End the current watch without an event.
    public func finishWatch() {
        lock.withLock {
            continuation?.finish()
            continuation = nil
        }
    }
}

/// A mock `CallCommandGating` whose pending command tests set by hand.
public final class MockCallCommandGate: CallCommandGating,
    @unchecked Sendable
{

    private let lock = NSLock()

    /// The command the next `takePendingCommand()` returns and
    /// consumes; nil simulates a content turn.
    public var pendingCommand: CallMetaCommand? {
        get { lock.withLock { _pendingCommand } }
        set { lock.withLock { _pendingCommand = newValue } }
    }
    private var _pendingCommand: CallMetaCommand?

    /// Number of times `reset()` was called.
    public var resetCount: Int { lock.withLock { _resetCount } }
    private var _resetCount = 0

    public init() {}

    public func takePendingCommand() async -> CallMetaCommand? {
        lock.withLock {
            let command = _pendingCommand
            _pendingCommand = nil
            return command
        }
    }

    public func reset() async {
        lock.withLock { _resetCount += 1 }
    }
}

/// A stub `MetaCommandInterpreting` returning a scripted command.
public final class StubMetaCommandInterpreter: MetaCommandInterpreting,
    @unchecked Sendable
{

    private let lock = NSLock()

    /// The command every utterance interprets to; nil means content.
    public var stubbedCommand: CallMetaCommand? {
        get { lock.withLock { _stubbedCommand } }
        set { lock.withLock { _stubbedCommand = newValue } }
    }
    private var _stubbedCommand: CallMetaCommand?

    /// Utterances passed to `interpret`, in order.
    public var interpretedUtterances: [String] {
        lock.withLock { _interpretedUtterances }
    }
    private var _interpretedUtterances: [String] = []

    public init(command: CallMetaCommand? = nil) {
        self._stubbedCommand = command
    }

    public func interpret(_ utterance: String) async -> CallMetaCommand? {
        lock.withLock {
            _interpretedUtterances.append(utterance)
            return _stubbedCommand
        }
    }
}

/// A mock `AgentFocusing` that records requested selections.
public final class MockAgentFocuser: AgentFocusing, @unchecked Sendable {

    public struct Request: Equatable, Sendable {
        public let bundleID: String
        public let processIdentifier: Int32?
        public let ttyDevice: Int32?

        public init(
            bundleID: String,
            processIdentifier: Int32?,
            ttyDevice: Int32?
        ) {
            self.bundleID = bundleID
            self.processIdentifier = processIdentifier
            self.ttyDevice = ttyDevice
        }
    }

    private let lock = NSLock()

    /// Selections passed to `focusSession`, in order.
    public var requests: [Request] {
        lock.withLock { _requests }
    }
    private var _requests: [Request] = []

    public init() {}

    public func focusSession(
        bundleID: String,
        processIdentifier: Int32?,
        ttyDevice: Int32?
    ) async {
        lock.withLock {
            _requests.append(
                Request(
                    bundleID: bundleID,
                    processIdentifier: processIdentifier,
                    ttyDevice: ttyDevice))
        }
    }
}

/// A mock `CallCuePlaying` that counts each cue.
public final class MockCallCuePlayer: CallCuePlaying, @unchecked Sendable {

    private let lock = NSLock()

    public var sendCueCount: Int { lock.withLock { _sendCueCount } }
    private var _sendCueCount = 0

    public var replyCueCount: Int { lock.withLock { _replyCueCount } }
    private var _replyCueCount = 0

    public var doneCueCount: Int { lock.withLock { _doneCueCount } }
    private var _doneCueCount = 0

    public init() {}

    public func playSendCue() { lock.withLock { _sendCueCount += 1 } }
    public func playReplyCue() { lock.withLock { _replyCueCount += 1 } }
    public func playDoneCue() { lock.withLock { _doneCueCount += 1 } }
}

/// A mock `TurnSubmitting` that counts submissions.
public final class MockTurnSubmitter: TurnSubmitting, @unchecked Sendable {

    private let lock = NSLock()

    /// Number of times `submitTurn()` was called.
    public var submitCount: Int { lock.withLock { _submitCount } }
    private var _submitCount = 0

    public init() {}

    public func submitTurn() async { lock.withLock { _submitCount += 1 } }
}

/// A mock `InjectionObserving` returning a scripted injection record.
public final class MockInjectionObserver: InjectionObserving,
    @unchecked Sendable
{

    private let lock = NSLock()

    /// The text `lastInjectedText()` reports; nil simulates a turn
    /// that injected nothing.
    public var stubbedText: String? {
        get { lock.withLock { _stubbedText } }
        set { lock.withLock { _stubbedText = newValue } }
    }
    private var _stubbedText: String?

    /// Number of times `reset()` was called.
    public var resetCount: Int { lock.withLock { _resetCount } }
    private var _resetCount = 0

    public init(text: String? = nil) {
        self._stubbedText = text
    }

    public func reset() async {
        lock.withLock { _resetCount += 1 }
    }

    public func lastInjectedText() async -> String? {
        lock.withLock { _stubbedText }
    }
}
