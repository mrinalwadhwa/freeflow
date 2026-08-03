import Foundation
import Testing

@testable import UnrambleKit

/// Fixture node mirroring the shapes browsers expose through the AX tree.
private struct FixtureNode: WebAccessibilityNode {
    var role: String?
    var subrole: String?
    var textValue: String?
    var children: [FixtureNode] = []

    static func text(_ value: String) -> FixtureNode {
        FixtureNode(role: "AXStaticText", textValue: value)
    }

    static func group(
        subrole: String? = nil, _ children: [FixtureNode]
    ) -> FixtureNode {
        FixtureNode(role: "AXGroup", subrole: subrole, children: children)
    }

    static func heading(_ value: String) -> FixtureNode {
        FixtureNode(role: "AXHeading", children: [.text(value)])
    }

    static func list(_ items: [[FixtureNode]]) -> FixtureNode {
        FixtureNode(
            role: "AXList",
            children: items.map { FixtureNode(role: "AXGroup", children: $0) })
    }
}

@Suite("Web content tree")
struct WebContentTreeTests {

    @Test("Headings, paragraphs, and lists become tagged segments")
    func collectsTaggedSegments() {
        let page = FixtureNode.group([
            .heading("The Title"),
            .group([.text("First paragraph,"), .text("in two nodes.")]),
            .group([.text("Second paragraph.")]),
            .list([[.text("One")], [.text("Two")]]),
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [
                .init(kind: .heading, text: "The Title"),
                .init(kind: .prose, text: "First paragraph, in two nodes."),
                .init(kind: .prose, text: "Second paragraph."),
                .init(kind: .listItem, text: "One"),
                .init(kind: .listItem, text: "Two"),
            ])
    }

    @Test("Empty and whitespace text nodes produce no segments")
    func skipsEmptyText() {
        let page = FixtureNode.group([
            .group([.text("  ")]),
            .group([.text("Kept.")]),
            .list([[.text("   ")]]),
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(segments == [.init(kind: .prose, text: "Kept.")])
    }

    @Test("An exhausted budget returns what was collected")
    func budgetBoundsCollection() {
        let page = FixtureNode.group(
            (0..<50).map { index in .group([.text("Paragraph \(index).")]) })

        let segments = WebContentTree.segments(under: page, budget: 20)

        #expect(!segments.isEmpty)
        #expect(segments.count < 50)
    }

    @Test("The main region prefers the ARIA main landmark")
    func mainRegionPrefersLandmark() {
        let webArea = FixtureNode.group([
            .group(subrole: "AXLandmarkNavigation", [.text("Nav")]),
            .group(subrole: "AXLandmarkMain", [.text("Main")]),
        ])

        let main = WebContentTree.mainRegion(of: webArea)

        #expect(main.subrole == "AXLandmarkMain")
    }

    @Test("The main region falls back to the document subrole")
    func mainRegionFallsBackToDocument() {
        let webArea = FixtureNode.group([
            .group(subrole: "AXDocument", [.text("Doc")])
        ])

        let main = WebContentTree.mainRegion(of: webArea)

        #expect(main.subrole == "AXDocument")
    }

    @Test("The main region falls back to the whole web area")
    func mainRegionFallsBackToWebArea() {
        let webArea = FixtureNode(
            role: "AXWebArea",
            children: [.group([.text("Everything")])])

        let main = WebContentTree.mainRegion(of: webArea)

        #expect(main.role == "AXWebArea")
    }

    @Test("Find honors its node budget")
    func findHonorsBudget() {
        let webArea = FixtureNode.group(
            (0..<100).map { _ in .group([.text("Filler")]) }
                + [.group(subrole: "AXLandmarkMain", [.text("Main")])])

        let found = WebContentTree.firstDescendant(
            of: webArea, subrole: "AXLandmarkMain", budget: 10)

        #expect(found == nil)
    }

    @Test("Paragraphs nested under a wrapper stay separate")
    func nestedParagraphsStaySeparate() {
        // The common page shape: main wraps an article wrapper that
        // holds the paragraphs, so paragraph boundaries are two levels
        // below the region root.
        let page = FixtureNode.group([
            .group([
                .group([.text("First paragraph.")]),
                .group([.text("Second paragraph.")]),
            ]),
            .group([.text("Next block.")]),
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [
                .init(kind: .prose, text: "First paragraph."),
                .init(kind: .prose, text: "Second paragraph."),
                .init(kind: .prose, text: "Next block."),
            ])
    }

    @Test("An inline link continues its paragraph")
    func inlineLinkContinuesParagraph() {
        let page = FixtureNode.group([
            .group([
                .text("Read the"),
                FixtureNode(role: "AXLink", children: [.text("full story")]),
                .text("here."),
            ])
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [
                .init(kind: .prose, text: "Read the full story here.")
            ])
    }

    @Test("A heading whose text sits inside a link is still one heading")
    func headingWithNestedLink() {
        let page = FixtureNode.group([
            FixtureNode(
                role: "AXHeading",
                children: [
                    FixtureNode(role: "AXLink", children: [.text("Linked title")])
                ])
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(segments == [.init(kind: .heading, text: "Linked title")])
    }

    @Test("An inline code span continues its paragraph")
    func inlineCodeSpanContinuesParagraph() {
        // Inline code and code blocks share the code subrole; a
        // single-line span with siblings is part of the sentence and
        // must not become a skipped code block.
        let page = FixtureNode.group([
            .group([
                .text("The result is"),
                FixtureNode(
                    role: "AXGroup", subrole: "AXCodeStyleGroup",
                    children: [.text("pass")]),
                .text("here."),
            ])
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [
                .init(kind: .prose, text: "The result is pass here.")
            ])
    }

    @Test("A standalone single-line code group stays a code block")
    func standaloneSingleLineCodeStaysBlock() {
        let page = FixtureNode.group([
            .group([
                FixtureNode(
                    role: "AXGroup", subrole: "AXCodeStyleGroup",
                    children: [.text("npx skills add fluent")])
            ]),
            .group([.text("Run it once.")]),
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [
                .init(kind: .code, text: "npx skills add fluent"),
                .init(kind: .prose, text: "Run it once."),
            ])
    }

    @Test("Bold and emphasis runs do not split their paragraph")
    func styleRunsDoNotSplitParagraph() {
        let page = FixtureNode.group([
            .group([
                .text("some"),
                FixtureNode(
                    role: "AXGroup", subrole: "AXStrongStyleGroup",
                    children: [.text("bold")]),
                .text("words."),
            ])
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [.init(kind: .prose, text: "some bold words.")])
    }

    @Test("A code-style group becomes a code segment with line breaks")
    func codeGroupBecomesCodeSegment() {
        let page = FixtureNode.group([
            FixtureNode(
                role: "AXGroup",
                subrole: "AXCodeStyleGroup",
                children: [.text("let x = 1"), .text("print(x)")]),
            .group([.text("After the code.")]),
        ])

        let segments = WebContentTree.segments(under: page)

        #expect(
            segments == [
                .init(kind: .code, text: "let x = 1\nprint(x)"),
                .init(kind: .prose, text: "After the code."),
            ])
    }

    @Test("Find matches by role")
    func findMatchesByRole() {
        let window = FixtureNode.group([
            .group([
                FixtureNode(
                    role: "AXWebArea",
                    children: [.group([.text("Page")])])
            ])
        ])

        let found = WebContentTree.firstDescendant(
            of: window, role: "AXWebArea")

        #expect(found?.role == "AXWebArea")
    }

    @Test("The main landmark wins even when a document appears first")
    func landmarkWinsOverEarlierDocument() {
        let webArea = FixtureNode.group([
            .group(subrole: "AXDocument", [.text("Doc")]),
            .group(subrole: "AXLandmarkMain", [.text("Main")]),
        ])

        let main = WebContentTree.mainRegion(of: webArea)

        #expect(main.subrole == "AXLandmarkMain")
    }

    @Test("A cancelled task collects nothing")
    func cancelledTaskCollectsNothing() async {
        let page = FixtureNode.group(
            (0..<50).map { index in .group([.text("Paragraph \(index).")]) })

        let task = Task { () -> [ReadableContent.Segment] in
            while !Task.isCancelled {
                await Task.yield()
            }
            return WebContentTree.segments(under: page)
        }
        task.cancel()

        #expect(await task.value.isEmpty)
    }
}
