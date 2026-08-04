import Foundation

/// Play the conversation call's cue sounds.
///
/// The send cue marks the moment a turn goes, the reply cue precedes
/// a spoken response, and the done cue marks a turn that ended with
/// only tool output. All cues are short; longer sounds measurably
/// delayed feedback when previously tried.
public protocol CallCuePlaying: Sendable {

    /// Mark the moment a turn is sent.
    func playSendCue()

    /// Announce that a spoken response follows.
    func playReplyCue()

    /// Mark a turn that completed without response text.
    func playDoneCue()
}
