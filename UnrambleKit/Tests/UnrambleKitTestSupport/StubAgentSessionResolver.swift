import Foundation

@testable import UnrambleKit

/// A stub `AgentSessionResolving` that returns a configurable session.
public final class StubAgentSessionResolver: AgentSessionResolving,
    @unchecked Sendable
{

    private let lock = NSLock()

    /// The session `resolveSession(for:)` returns; nil means no
    /// coding-agent session is reachable.
    public var stubbedSession: ResolvedAgentSession? {
        get { lock.withLock { _stubbedSession } }
        set { lock.withLock { _stubbedSession = newValue } }
    }
    private var _stubbedSession: ResolvedAgentSession?

    /// Number of times `resolveSession(for:)` was called.
    public var resolveCallCount: Int {
        lock.withLock { _resolveCallCount }
    }
    private var _resolveCallCount = 0

    private var queued: [ResolvedAgentSession?] = []

    public init(session: ResolvedAgentSession? = nil) {
        self._stubbedSession = session
    }

    /// Script the next resolutions in order; once the queue drains,
    /// `stubbedSession` answers again.
    public func enqueue(_ session: ResolvedAgentSession?) {
        lock.withLock { queued.append(session) }
    }

    public func resolveSession(
        for context: AppContext
    ) async -> ResolvedAgentSession? {
        lock.withLock {
            _resolveCallCount += 1
            if !queued.isEmpty {
                return queued.removeFirst()
            }
            return _stubbedSession
        }
    }
}
