import Foundation

/// Reads the text produced by asking the frontmost application to copy.
///
/// This is a compatibility escape hatch for custom editors that do not expose
/// their selection through macOS Accessibility. Implementations must restore
/// the previous pasteboard when it has not been changed by another process.
public protocol CopySelectionReading: Sendable {

    /// Copy and return the application's readable focus, or nil when the copy
    /// command did not produce text. Some custom editors intentionally copy the
    /// current line when they have no selection.
    func copySelectedText() async -> String?
}
