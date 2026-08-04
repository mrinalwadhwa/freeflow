import Foundation

/// Hand a call turn's intercepted meta-command to its consumer.
public protocol CallCommandGating: Sendable {

    /// Return and consume the command the most recent call turn
    /// produced, or nil when the turn was content.
    func takePendingCommand() async -> CallMetaCommand?

    /// Discard any pending command, as at the start of a turn.
    func reset() async
}
