import Foundation

/// Reads a selection by asking the frontmost application to copy it.
///
/// This is a compatibility escape hatch for custom editors that do not expose
/// their selection through macOS Accessibility. Implementations must restore
/// the previous pasteboard when it has not been changed by another process.
public protocol CopySelectionReading: Sendable {

    /// Copy and return the current selection, or nil when the copy command did
    /// not produce text.
    func copySelectedText() async -> String?
}
