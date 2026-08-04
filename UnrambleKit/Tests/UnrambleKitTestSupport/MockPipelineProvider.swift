import Foundation

@testable import UnrambleKit

/// A mock `PipelineProviding` that records lifecycle calls and settles
/// state transitions synchronously.
///
/// `activate()` returns a fresh session ID (or nil when scripted to
/// fail) and moves the state to `.recording`; `complete` and `cancel`
/// return it to `.idle`. Tests inspect the recorded session IDs to
/// verify which sessions were completed or cancelled.
public final class MockPipelineProvider: PipelineProviding, @unchecked Sendable
{

    private let lock = NSLock()

    /// When true, the next `activate()` returns nil, simulating a
    /// pipeline that refused the session.
    public var nextActivateFails: Bool {
        get { lock.withLock { _nextActivateFails } }
        set { lock.withLock { _nextActivateFails = newValue } }
    }
    private var _nextActivateFails = false

    /// Session IDs accepted by `activate()`, in order.
    public var activatedSessionIDs: [DictationSessionID] {
        lock.withLock { _activatedSessionIDs }
    }
    private var _activatedSessionIDs: [DictationSessionID] = []

    /// Session IDs passed to `complete(sessionID:)`, in order.
    public var completedSessionIDs: [DictationSessionID] {
        lock.withLock { _completedSessionIDs }
    }
    private var _completedSessionIDs: [DictationSessionID] = []

    /// Session IDs passed to `cancel(sessionID:)`, in order.
    public var cancelledSessionIDs: [DictationSessionID] {
        lock.withLock { _cancelledSessionIDs }
    }
    private var _cancelledSessionIDs: [DictationSessionID] = []

    private var _state: RecordingState = .idle
    private var _currentSessionID: DictationSessionID?

    public init() {}

    public var state: RecordingState {
        lock.withLock { _state }
    }

    public var currentSessionID: DictationSessionID? {
        lock.withLock { _currentSessionID }
    }

    @discardableResult
    public func activate() async -> DictationSessionID? {
        lock.withLock {
            guard !_nextActivateFails else {
                _nextActivateFails = false
                return nil
            }
            let sessionID = DictationSessionID()
            _activatedSessionIDs.append(sessionID)
            _state = .recording
            _currentSessionID = sessionID
            return sessionID
        }
    }

    public func complete() async {
        let sessionID = lock.withLock { _currentSessionID }
        guard let sessionID else { return }
        await complete(sessionID: sessionID)
    }

    public func complete(sessionID: DictationSessionID) async {
        lock.withLock {
            _completedSessionIDs.append(sessionID)
            if _currentSessionID == sessionID {
                _state = .idle
                _currentSessionID = nil
            }
        }
    }

    public func cancel() async {
        let sessionID = lock.withLock { _currentSessionID }
        guard let sessionID else { return }
        await cancel(sessionID: sessionID)
    }

    public func cancel(sessionID: DictationSessionID) async {
        lock.withLock {
            _cancelledSessionIDs.append(sessionID)
            if _currentSessionID == sessionID {
                _state = .idle
                _currentSessionID = nil
            }
        }
    }
}
