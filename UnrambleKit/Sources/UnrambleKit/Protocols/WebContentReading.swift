import Foundation

/// Reads the main content region of a browser page.
public protocol WebContentReading: Sendable {

    /// Read the page's main content from the application's focused window.
    ///
    /// - Parameter processIdentifier: The browser application's process ID.
    /// - Returns: Structured content, or nil when no web area or no
    ///   speakable text is reachable.
    func readMainContent(processIdentifier: Int32) async -> ReadableContent?
}
