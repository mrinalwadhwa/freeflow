import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Selection content source")
struct SelectionContentSourceTests {

    @Test("Uses the snapshot selection without a live read")
    func usesSnapshotSelection() async throws {
        let reader = MockSelectionReader(stubbedSelection: "live value")
        let source = SelectionContentSource(selectionReader: reader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled",
            selectedText: "snapshot value")

        let content = try await source.readContent(for: context)

        #expect(content?.segments == [
            .init(kind: .prose, text: "snapshot value")
        ])
        #expect(reader.readCount == 0)
    }

    @Test("Falls back to a live read when the snapshot has no selection")
    func fallsBackToLiveRead() async throws {
        let reader = MockSelectionReader(stubbedSelection: "from web page")
        let source = SelectionContentSource(selectionReader: reader)

        let content = try await source.readContent(for: .stub)

        #expect(content?.segments == [
            .init(kind: .prose, text: "from web page")
        ])
        #expect(reader.readCount == 1)
    }

    @Test("A whitespace-only snapshot selection falls back to a live read")
    func whitespaceSnapshotFallsBack() async throws {
        let reader = MockSelectionReader(stubbedSelection: "live")
        let source = SelectionContentSource(selectionReader: reader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled",
            selectedText: "  \n ")

        let content = try await source.readContent(for: context)

        #expect(content?.segments == [.init(kind: .prose, text: "live")])
        #expect(reader.readCount == 1)
    }

    @Test("Returns nil when nothing is selected")
    func returnsNilWithoutSelection() async throws {
        let reader = MockSelectionReader(stubbedSelection: nil)
        let source = SelectionContentSource(selectionReader: reader)
        #expect(try await source.readContent(for: .stub) == nil)
    }

    @Test("Treats a whitespace-only selection as no selection")
    func ignoresWhitespaceSelection() async throws {
        let reader = MockSelectionReader(stubbedSelection: "  \n ")
        let source = SelectionContentSource(selectionReader: reader)
        #expect(try await source.readContent(for: .stub) == nil)
    }
}
