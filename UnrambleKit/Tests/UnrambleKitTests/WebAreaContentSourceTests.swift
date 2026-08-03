import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Web-area content source")
struct WebAreaContentSourceTests {

    private func browserContext(
        pid: Int32? = 400,
        windowTitle: String = "An Article — Safari"
    ) -> AppContext {
        AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: windowTitle,
            processIdentifier: pid)
    }

    private let pageContent = ReadableContent(segments: [
        .init(kind: .heading, text: "An Article"),
        .init(kind: .prose, text: "Body text."),
    ])

    @Test("Reads the page content without a window-title preamble")
    func readsPageWithoutTitlePreamble() async throws {
        // Articles lead with their own headline; speaking the window
        // title first would repeat it.
        let reader = MockWebContentReader(stubbedContent: pageContent)
        let source = WebAreaContentSource(webReader: reader)

        let content = try await source.readContent(for: browserContext())

        #expect(content?.title == nil)
        #expect(content?.segments == pageContent.segments)
        #expect(reader.requestedProcessIdentifiers == [400])
    }

    @Test("Returns nil for a non-browser app without reading")
    func returnsNilForNonBrowser() async throws {
        let reader = MockWebContentReader(stubbedContent: pageContent)
        let source = WebAreaContentSource(webReader: reader)
        let context = AppContext(
            bundleID: "com.apple.TextEdit",
            appName: "TextEdit",
            windowTitle: "Untitled",
            processIdentifier: 400)

        #expect(try await source.readContent(for: context) == nil)
        #expect(reader.requestedProcessIdentifiers.isEmpty)
    }

    @Test("Returns nil when the snapshot has no process identifier")
    func returnsNilWithoutPid() async throws {
        let reader = MockWebContentReader(stubbedContent: pageContent)
        let source = WebAreaContentSource(webReader: reader)

        #expect(
            try await source.readContent(for: browserContext(pid: nil)) == nil)
        #expect(reader.requestedProcessIdentifiers.isEmpty)
    }

    @Test("Returns nil when the page yields no content")
    func returnsNilWithoutPageContent() async throws {
        let reader = MockWebContentReader(stubbedContent: nil)
        let source = WebAreaContentSource(webReader: reader)

        #expect(try await source.readContent(for: browserContext()) == nil)
    }

    @Test("Returns nil when the page yields only whitespace")
    func returnsNilForWhitespacePage() async throws {
        let reader = MockWebContentReader(
            stubbedContent: ReadableContent(segments: [
                .init(kind: .prose, text: "  \n ")
            ]))
        let source = WebAreaContentSource(webReader: reader)

        #expect(try await source.readContent(for: browserContext()) == nil)
    }
}
