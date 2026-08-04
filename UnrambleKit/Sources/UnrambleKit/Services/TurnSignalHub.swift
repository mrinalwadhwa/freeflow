import Foundation

/// Fan out `TurnSignal`s from the streaming providers to the
/// conversation call.
///
/// Providers publish signals for the session they are transcribing;
/// the call coordinator subscribes to the session it is listening on.
/// Publishing to a session nobody observes drops the signal, so
/// ordinary dictation pays nothing for the hub.
public final class TurnSignalHub: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations:
        [DictationSessionID: [UUID: AsyncStream<TurnSignal>.Continuation]] =
            [:]

    public init() {}

    /// Publish a signal to every observer of the session.
    public func publish(
        _ signal: TurnSignal,
        for sessionID: DictationSessionID
    ) {
        let observers = lock.withLock {
            continuations[sessionID].map { Array($0.values) } ?? []
        }
        guard !observers.isEmpty else { return }
        Log.debug("[TurnSignal] \(signal)")
        for continuation in observers {
            continuation.yield(signal)
        }
    }

    /// Stream the session's signals from subscription onward.
    public func signals(
        for sessionID: DictationSessionID
    ) -> AsyncStream<TurnSignal> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock {
                continuations[sessionID, default: [:]][id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    _ = self.continuations[sessionID]?.removeValue(forKey: id)
                    if self.continuations[sessionID]?.isEmpty == true {
                        self.continuations[sessionID] = nil
                    }
                }
            }
        }
    }

    /// Finish every observer of a session that ended.
    public func endSession(_ sessionID: DictationSessionID) {
        let observers = lock.withLock {
            let ended = continuations[sessionID].map { Array($0.values) } ?? []
            continuations[sessionID] = nil
            return ended
        }
        for continuation in observers {
            continuation.finish()
        }
    }
}
