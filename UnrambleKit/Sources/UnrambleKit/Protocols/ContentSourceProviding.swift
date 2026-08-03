import Foundation

/// Acquires readable content from the frontmost application.
///
/// Each conforming source hides one acquisition strategy: selected text,
/// a coding-agent transcript, a web page's main region. The read session
/// coordinator tries sources in the order the selector returns them and
/// takes the first non-empty result. A source that throws or returns nil
/// falls through to the next source.
public protocol ContentSourceProviding: Sendable {

    /// Read content for the given snapshot, or nil when this source does
    /// not apply. Implementations must not mutate the frontmost app's focus,
    /// selection, or scroll position. A compatibility source may temporarily
    /// use the pasteboard only when it restores the prior contents unless an
    /// external process changed them in the meantime.
    func readContent(for context: AppContext) async throws -> ReadableContent?
}
