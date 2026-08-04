import Foundation

/// Watch one coding-agent session for the response to a sent turn.
///
/// A conversation call arms a watch when a turn is sent to an agent
/// target; arming replaces any earlier watch, and hangup cancels it.
/// The returned stream delivers the watch's events and finishes when
/// the watch ends — through an event, replacement, or cancellation.
public protocol ResponseWatching: Sendable {

    /// Watch the session for the response to the turn whose injected
    /// text anchors it, replacing any earlier watch.
    func arm(
        session: ResolvedAgentSession,
        anchor: String
    ) async -> AsyncStream<ResponseWatchEvent>

    /// Cancel any armed watch.
    func cancelWatch() async
}
