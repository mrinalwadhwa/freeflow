import Foundation

/// Outcome of watching a coding-agent session for a sent turn.
public enum ResponseWatchEvent: Sendable, Equatable {

    /// A mostly-prose assistant message arrived while the turn is
    /// still running; interim narration speaks it on arrival.
    case interimMessage(markdown: String)

    /// The response completed: the transcript went still with new
    /// assistant text at its edge that narration has not yet spoken.
    case response(markdown: String)

    /// The response completed after interim narration already offered
    /// its text. The markdown rides along so a consumer that dropped
    /// the narration — a barge-in window — can still speak it.
    case completed(markdown: String)

    /// The turn produced no new assistant text within the extended
    /// window — tool output only, a dead transcript, or a turn that
    /// landed elsewhere.
    case toolOnly
}
