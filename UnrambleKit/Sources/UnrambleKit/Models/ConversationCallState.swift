import Foundation

/// Phase of the conversation call the HUD shows.
///
/// A call cycles listening → waiting → speaking → listening until the
/// user hangs up. `idle` means no call is active; nothing is ever
/// spoken automatically outside a call.
public enum ConversationCallState: Sendable, Equatable {

    /// No call is active.
    case idle

    /// The call captures the user's speech; a stretch of transcription
    /// stillness sends the turn.
    case listening

    /// A turn was sent; the call watches the agent session for its
    /// response while the microphone stays open — speech during the
    /// wait endpoints normally and supersedes the watch.
    case waiting

    /// The call speaks a response or an interim message.
    case speaking

    /// No call started because the frontmost window hosts no
    /// coding-agent session; the HUD shows guidance until dismissal.
    case noAgent
}
