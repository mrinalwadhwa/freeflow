import Foundation

/// Reads the main content of the frontmost browser page as content to
/// speak.
///
/// Applies only when the snapshot's app is a known browser; other apps
/// fall through to later sources. The read dives straight into the
/// page's content — articles lead with their own headline, so speaking
/// the window title first would repeat it.
public struct WebAreaContentSource: ContentSourceProviding {

    private let webReader: any WebContentReading

    public init(webReader: any WebContentReading) {
        self.webReader = webReader
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        guard BrowserURLReader.isBrowser(bundleID: context.bundleID) else {
            return nil
        }
        guard let pid = context.processIdentifier else { return nil }
        guard
            let content = await webReader.readMainContent(
                processIdentifier: pid),
            !content.isEmpty
        else { return nil }

        return ReadableContent(segments: content.segments)
    }
}
