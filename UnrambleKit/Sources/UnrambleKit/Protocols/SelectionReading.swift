import Foundation

/// Reads the currently selected text anywhere on screen.
///
/// Unlike the dictation context snapshot, which reads selection only from
/// text-input elements, this read applies to any focused element role so a
/// selection in a web page or a document viewer is also readable.
public protocol SelectionReading: Sendable {

    /// Return the focused element's selected text, or nil when nothing is
    /// selected or the element is unreadable.
    func readSelectedText() async -> String?
}
