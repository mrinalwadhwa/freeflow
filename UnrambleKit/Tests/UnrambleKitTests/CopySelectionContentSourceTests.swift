import Testing

@testable import UnrambleKit

@Suite("Copy selection content source")
struct CopySelectionContentSourceTests {

    @Test("Reads copied text only for an explicitly supported app")
    func readsSupportedApp() async throws {
        let reader = StubCopySelectionReader(text: "selected in Zed")
        let source = CopySelectionContentSource(
            supportedBundleIDs: ["dev.zed.Zed"],
            selectionReader: reader)
        let context = AppContext(
            bundleID: "dev.zed.Zed", appName: "Zed", windowTitle: "notes")

        let content = try await source.readContent(for: context)

        #expect(content?.segments == [
            .init(kind: .prose, text: "selected in Zed")
        ])
        #expect(await reader.readCount == 1)
    }

    @Test("Does not issue Copy in another app")
    func ignoresUnsupportedApp() async throws {
        let reader = StubCopySelectionReader(text: "should not be read")
        let source = CopySelectionContentSource(
            supportedBundleIDs: ["dev.zed.Zed"],
            selectionReader: reader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit", appName: "TextEdit",
            windowTitle: "notes")

        #expect(try await source.readContent(for: context) == nil)
        #expect(await reader.readCount == 0)
    }

    @Test("Treats an empty copied selection as no content")
    func ignoresEmptyCopy() async throws {
        let reader = StubCopySelectionReader(text: " \n ")
        let source = CopySelectionContentSource(
            supportedBundleIDs: ["dev.zed.Zed"],
            selectionReader: reader)
        let context = AppContext(
            bundleID: "dev.zed.Zed", appName: "Zed", windowTitle: "notes")

        #expect(try await source.readContent(for: context) == nil)
    }
}

private actor StubCopySelectionReader: CopySelectionReading {
    let text: String?
    private(set) var readCount = 0

    init(text: String?) {
        self.text = text
    }

    func copySelectedText() -> String? {
        readCount += 1
        return text
    }
}
