import Foundation

/// A node in a web page's accessibility tree, abstracted so main-region
/// location and text collection are testable without live AX elements.
protocol WebAccessibilityNode {
    var role: String? { get }
    var subrole: String? { get }
    var textValue: String? { get }
    var children: [Self] { get }
}

/// Locate a page's main content region and collect speakable segments.
///
/// Every attribute read on a live tree is IPC to the browser, so all
/// walks carry node budgets and depth caps, and every visit checks task
/// cancellation so an abandoned read unwinds promptly instead of
/// hammering the browser. An exhausted budget returns what was
/// collected rather than failing. ARIA landmarks reach the AX tree as
/// subroles, so the main-region locator is standards-based, not
/// per-site.
enum WebContentTree {

    private static let findDepthLimit = 25
    private static let collectDepthLimit = 30

    /// Roles that continue the surrounding paragraph rather than starting
    /// a block of their own.
    private static let inlineRoles: Set<String> = ["AXLink"]

    // MARK: - Find

    /// Depth-first search for the first descendant matching a role and/or
    /// subrole, spending at most `budget` node visits.
    static func firstDescendant<Node: WebAccessibilityNode>(
        of root: Node,
        role: String? = nil,
        subrole: String? = nil,
        budget: Int = 6000
    ) -> Node? {
        var remaining = budget
        return firstDescendant(
            of: root, role: role, subrole: subrole, depth: 0,
            remaining: &remaining)
    }

    private static func firstDescendant<Node: WebAccessibilityNode>(
        of node: Node,
        role: String?,
        subrole: String?,
        depth: Int,
        remaining: inout Int
    ) -> Node? {
        guard depth <= findDepthLimit, remaining > 0, !Task.isCancelled
        else { return nil }
        remaining -= 1
        if role == nil || node.role == role,
            subrole == nil || node.subrole == subrole
        {
            return node
        }
        for child in node.children {
            if let found = firstDescendant(
                of: child, role: role, subrole: subrole, depth: depth + 1,
                remaining: &remaining)
            {
                return found
            }
        }
        return nil
    }

    /// The region whose text a read session speaks: the ARIA main
    /// landmark, else the document subrole, else the whole web area.
    /// One scan finds both candidates so pages without a main landmark
    /// do not pay for a second walk over the same nodes.
    static func mainRegion<Node: WebAccessibilityNode>(
        of webArea: Node,
        budget: Int = 6000
    ) -> Node {
        var remaining = budget
        var document: Node?
        if let main = scanForMainLandmark(
            webArea, depth: 0, remaining: &remaining, document: &document)
        {
            return main
        }
        return document ?? webArea
    }

    private static func scanForMainLandmark<Node: WebAccessibilityNode>(
        _ node: Node,
        depth: Int,
        remaining: inout Int,
        document: inout Node?
    ) -> Node? {
        guard depth <= findDepthLimit, remaining > 0, !Task.isCancelled
        else { return nil }
        remaining -= 1
        switch node.subrole {
        case "AXLandmarkMain":
            return node
        case "AXDocument":
            if document == nil { document = node }
        default:
            break
        }
        for child in node.children {
            if let found = scanForMainLandmark(
                child, depth: depth + 1, remaining: &remaining,
                document: &document)
            {
                return found
            }
        }
        return nil
    }

    // MARK: - Collect

    /// Collect speakable segments under a region.
    ///
    /// Headings, list items, and code blocks become their own tagged
    /// segments. Static text accumulates into an open paragraph that
    /// closes when the block directly containing it ends, so sibling
    /// paragraphs stay separate however deeply a page nests its
    /// wrappers; inline containers such as links continue the paragraph.
    static func segments<Node: WebAccessibilityNode>(
        under root: Node,
        budget: Int = 20000
    ) -> [ReadableContent.Segment] {
        var collector = Collector(remaining: budget)
        let children = root.children
        for child in children {
            _ = collector.walk(
                child, depth: 1, isOnlyChild: children.count == 1)
            collector.flushProse()
        }
        collector.flushProse()
        return collector.segments
    }

    private struct Collector {
        var segments: [ReadableContent.Segment] = []
        var proseParts: [String] = []
        var remaining: Int

        /// Walk one node. Returns true when the node contributed inline
        /// text to the open paragraph, so the block that directly
        /// contains it knows to close the paragraph when it ends.
        mutating func walk<Node: WebAccessibilityNode>(
            _ node: Node, depth: Int, isOnlyChild: Bool
        ) -> Bool {
            guard depth <= collectDepthLimit, remaining > 0 else {
                return false
            }
            if Task.isCancelled {
                remaining = 0
                return false
            }
            remaining -= 1

            switch node.role {
            case "AXHeading":
                flushProse()
                append(kind: .heading, text: subtreeText(of: node))
                return false
            case "AXList":
                flushProse()
                for item in node.children {
                    guard remaining > 0, !Task.isCancelled else { break }
                    append(kind: .listItem, text: subtreeText(of: item))
                }
                return false
            case "AXStaticText":
                guard let value = node.textValue else { return false }
                proseParts.append(value)
                return true
            default:
                let subrole = node.subrole
                if subrole == "AXCodeStyleGroup" {
                    // Inline code spans and code blocks share this
                    // subrole. A span mid-paragraph continues the prose;
                    // a multi-line or standalone group is a real block.
                    let text = subtreeText(of: node, separator: "\n")
                    if !text.contains("\n"), !isOnlyChild {
                        proseParts.append(text)
                        return true
                    }
                    flushProse()
                    append(kind: .code, text: text)
                    return false
                }
                // Styling runs (bold, emphasis) are inline: they must
                // not close the paragraph around them.
                let isStyleRun = subrole?.hasSuffix("StyleGroup") == true
                var contributedText = false
                let children = node.children
                for child in children {
                    if walk(
                        child, depth: depth + 1,
                        isOnlyChild: children.count == 1)
                    {
                        contributedText = true
                    }
                }
                if isStyleRun || Self.isInline(node) {
                    return contributedText
                }
                if contributedText {
                    flushProse()
                }
                return false
            }
        }

        private static func isInline<Node: WebAccessibilityNode>(
            _ node: Node
        ) -> Bool {
            guard let role = node.role else { return false }
            return WebContentTree.inlineRoles.contains(role)
        }

        /// Join every static text beneath a node, for elements whose
        /// subtree reads as one unit (a heading, a list item, a code
        /// block).
        mutating func subtreeText<Node: WebAccessibilityNode>(
            of node: Node, separator: String = " "
        ) -> String {
            var parts: [String] = []
            gatherText(of: node, depth: 0, into: &parts)
            return parts.joined(separator: separator)
        }

        private mutating func gatherText<Node: WebAccessibilityNode>(
            of node: Node, depth: Int, into parts: inout [String]
        ) {
            guard depth <= collectDepthLimit, remaining > 0 else { return }
            if Task.isCancelled {
                remaining = 0
                return
            }
            remaining -= 1
            if node.role == "AXStaticText", let value = node.textValue {
                parts.append(value)
            }
            for child in node.children {
                gatherText(of: child, depth: depth + 1, into: &parts)
            }
        }

        mutating func flushProse() {
            guard !proseParts.isEmpty else { return }
            append(kind: .prose, text: proseParts.joined(separator: " "))
            proseParts = []
        }

        mutating func append(kind: ReadableContent.Segment.Kind, text: String) {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            segments.append(.init(kind: kind, text: text))
        }
    }
}
