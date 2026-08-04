import Foundation

/// Bring the pinned conversation's pane forward so a turn can be
/// delivered to it.
public protocol AgentFocusing: Sendable {

    /// Select the session owning the tty inside the terminal — the
    /// exact tab and pane, not just the application — and give focus
    /// a moment to settle before injection follows.
    func focusSession(
        bundleID: String,
        processIdentifier: Int32?,
        ttyDevice: Int32?
    ) async
}
