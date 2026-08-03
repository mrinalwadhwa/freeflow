import Foundation

/// Reads selected text through a temporary Copy command for explicitly
/// supported applications that do not expose selections through Accessibility.
public struct CopySelectionContentSource: ContentSourceProviding {

    private let supportedBundleIDs: Set<String>
    private let selectionReader: any CopySelectionReading

    public init(
        supportedBundleIDs: Set<String>,
        selectionReader: any CopySelectionReading
    ) {
        self.supportedBundleIDs = supportedBundleIDs
        self.selectionReader = selectionReader
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        guard supportedBundleIDs.contains(context.bundleID) else { return nil }
        guard let selection = await selectionReader.copySelectedText(),
            !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        return ReadableContent(
            segments: [.init(kind: .prose, text: selection)])
    }
}
