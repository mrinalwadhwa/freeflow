import Foundation

/// Reads which terminal session has keyboard focus.
public protocol TerminalFocusReading: Sendable {

    /// The tty device number of the frontmost terminal's focused session
    /// (the pane that would receive typed text), or nil when the terminal
    /// cannot or will not report it.
    func focusedSessionTTY(bundleID: String) async -> Int32?
}
