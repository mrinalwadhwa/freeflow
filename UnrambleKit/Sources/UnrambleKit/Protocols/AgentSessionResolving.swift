import Foundation

/// A coding-agent session reachable from the frontmost application.
public struct ResolvedAgentSession: Sendable, Equatable {

    /// Display name of the agent running the session.
    public let agentName: String

    /// Working directory of the agent process; transcript locators key
    /// their session files off it.
    public let workingDirectory: String

    /// Controlling tty device number of the agent process, when the
    /// process table reports one. Focused-pane scoping compares
    /// against it.
    public let ttyDevice: Int32?

    public init(
        agentName: String,
        workingDirectory: String,
        ttyDevice: Int32? = nil
    ) {
        self.agentName = agentName
        self.workingDirectory = workingDirectory
        self.ttyDevice = ttyDevice
    }
}

/// Resolves the coding-agent session behind an application snapshot.
///
/// A conversation call starts only when the frontmost window hosts a
/// coding-agent session; the same resolution scopes each send to the
/// focused pane.
public protocol AgentSessionResolving: Sendable {

    /// Return the agent session the user is looking at for this
    /// snapshot, or nil when none is reachable.
    func resolveSession(for context: AppContext) async -> ResolvedAgentSession?
}
