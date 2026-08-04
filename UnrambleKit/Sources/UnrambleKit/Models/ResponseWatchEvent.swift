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

    /// The transcript changed without narratable prose at its edge —
    /// tool records landing while the agent works. Not a resolution:
    /// the watch continues, and the call holds its idle window open
    /// because the conversation is visibly alive.
    case stillWorking

    /// The turn produced no new assistant text and the transcript
    /// went completely still for the extended window — a dead
    /// transcript, or a turn that landed elsewhere.
    case toolOnly
}
