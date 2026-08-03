import Foundation

/// Reads the user's current text selection as content to speak.
///
/// Prefers the selection captured in the snapshot at the hotkey press;
/// falls back to a live read that covers elements the snapshot skips,
/// such as selections in web pages and document viewers.
public struct SelectionContentSource: ContentSourceProviding {

    private let selectionReader: any SelectionReading

    public init(selectionReader: any SelectionReading) {
        self.selectionReader = selectionReader
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        let selection: String?
        if let snapshotSelection = context.selectedText,
            !snapshotSelection.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        {
            selection = snapshotSelection
        } else {
            selection = await selectionReader.readSelectedText()
        }

        guard let selection,
            !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return ReadableContent(
            segments: [.init(kind: .prose, text: selection)])
    }
}
