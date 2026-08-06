import Foundation

/// A node in a chat app's accessibility tree, abstracted so message
/// location and extraction are testable without live AX elements.
///
/// Chat apps (Slack, Discord) are Electron shells, so their UI reaches
/// the accessibility tree as a Chromium web area. Unlike article pages,
/// their structure carries DOM identifiers and ARIA descriptions that
/// name the parts — those, not visual order, anchor the walk.
protocol ChatAccessibilityNode {
    var role: String? { get }
    var subrole: String? { get }
    var axDescription: String? { get }
    var domIdentifier: String? { get }
    var textValue: String? { get }
    var children: [Self] { get }
}

/// Locate a chat panel's message list and extract its last message.
///
/// Anchors verified against Discord's live tree: the list is an
/// `AXList` described "Messages in <channel>", each message an
/// `AXGroup` whose DOM id starts with `chat-messages`, with
/// `message-username-*`, `message-content-*`, `message-reply-context-*`
/// descendants. Slack labels its message region the same ARIA way, so
/// the locator matches on the described list and falls back to
/// structural extraction when the Discord DOM ids are absent.
enum ChatMessageTree {

    private static let findDepthLimit = 30

    /// The last message of a list: who wrote it and its text blocks.
    struct LastMessage: Equatable {
        let attribution: String?
        let blocks: [String]
    }

    // MARK: - Find the message list

    /// Depth-first search for the message list under a root, spending
    /// at most `budget` node visits. The list announces itself through
    /// its ARIA label ("Messages in general", "Messages in #channel"),
    /// so the match is on the described role, not position.
    static func messageList<Node: ChatAccessibilityNode>(
        under root: Node, budget: Int = 5000
    ) -> Node? {
        var remaining = budget
        return firstMessageList(of: root, depth: 0, remaining: &remaining)
    }

    private static func firstMessageList<Node: ChatAccessibilityNode>(
        of node: Node, depth: Int, remaining: inout Int
    ) -> Node? {
        guard remaining > 0, depth <= findDepthLimit, !Task.isCancelled
        else { return nil }
        remaining -= 1
        if node.role == "AXList",
            let description = node.axDescription?.lowercased(),
            description.contains("message")
        {
            return node
        }
        for child in node.children {
            if let found = firstMessageList(
                of: child, depth: depth + 1, remaining: &remaining)
            {
                return found
            }
        }
        return nil
    }

    // MARK: - Extract the last message

    /// The last message in the list with speakable text, with its
    /// author. Consecutive messages by one author share a single
    /// username header, so a last message without one takes its
    /// author from the nearest earlier sibling that has one. A reply
    /// header ("mrinal replying to arthur360") supersedes the bare
    /// username — it carries both parties.
    static func lastMessage<Node: ChatAccessibilityNode>(
        in list: Node
    ) -> LastMessage? {
        let items = list.children
        // Slack's thread panel renders the reply composer as the
        // list's last item; an item holding a text field is input
        // chrome, not a message.
        guard
            let index = items.lastIndex(where: {
                !containsComposer($0) && !textBlocks(in: $0).isEmpty
            })
        else { return nil }
        let item = items[index]
        let reply = firstDescendant(of: item) {
            $0.domIdentifier?.contains("message-reply-context") == true
        }?.axDescription
        var author = collectedText(
            under: firstDescendant(of: item) {
                $0.domIdentifier?.contains("message-username") == true
            })
        if author == nil {
            for earlier in items[..<index].reversed() {
                if let named = firstDescendant(of: earlier, where: {
                    $0.domIdentifier?.contains("message-username") == true
                }) {
                    author = collectedText(under: named)
                    break
                }
            }
        }
        let attribution = reply.flatMap { $0.isEmpty ? nil : $0 } ?? author
        return LastMessage(
            attribution: attribution, blocks: textBlocks(in: item))
    }

    /// The message's text as one block per top-level content child, so
    /// paragraphs stay separate sentences when spoken. Content lives
    /// under the `message-content` descendant when the app provides
    /// one (Discord); otherwise the whole item is collected with the
    /// same skip rules (Slack's items carry no content wrapper).
    private static func textBlocks<Node: ChatAccessibilityNode>(
        in item: Node
    ) -> [String] {
        let content =
            firstDescendant(of: item) {
                $0.domIdentifier?.contains("message-content") == true
            } ?? item
        return collectBlocks(under: content, depth: 0)
    }

    /// Collect speakable blocks under a node, one per child subtree.
    ///
    /// A block that opens with thread meta ("replied to a thread:
    /// <snippet>") is chrome, but Slack wraps the meta row and the
    /// message body in one container, so the block's text alone
    /// cannot say where the meta ends. Structure can: the meta row
    /// is always the container's first text-bearing child, so a
    /// meta-opening block descends and sheds exactly that first
    /// child (recursively, in case the row is itself wrapped) while
    /// everything after it is body.
    private static func collectBlocks<Node: ChatAccessibilityNode>(
        under node: Node, depth: Int
    ) -> [String] {
        guard depth <= findDepthLimit else { return [] }
        var blocks: [String] = []
        for child in node.children where !isExcluded(child) {
            let text = normalized(gatherText(under: child))
            guard !text.isEmpty, !isTimestampShaped(text) else { continue }
            if opensWithThreadMeta(text) {
                blocks.append(
                    contentsOf: sheddingLeadingMeta(
                        child, depth: depth + 1))
                continue
            }
            blocks.append(text)
        }
        return blocks
    }

    /// Drop the leading meta row inside a meta-opening container and
    /// collect what follows as blocks. A meta-opening node with no
    /// children is the meta text itself and yields nothing.
    private static func sheddingLeadingMeta<Node: ChatAccessibilityNode>(
        _ node: Node, depth: Int
    ) -> [String] {
        guard depth <= findDepthLimit, !node.children.isEmpty else {
            return []
        }
        var blocks: [String] = []
        var metaShed = false
        for child in node.children where !isExcluded(child) {
            let text = normalized(gatherText(under: child))
            guard !text.isEmpty, !isTimestampShaped(text) else { continue }
            if !metaShed {
                metaShed = true
                if opensWithThreadMeta(text) {
                    // The first text under the container carries the
                    // meta; shed it — descending further when it
                    // still bundles body text of its own.
                    blocks.append(
                        contentsOf: sheddingLeadingMeta(
                            child, depth: depth + 1))
                    continue
                }
            }
            blocks.append(text)
        }
        return blocks
    }

    /// Whether a collected block is message chrome rather than the
    /// message: a bare timestamp or a thread-meta opening.
    static func isMetaBlock(_ text: String) -> Bool {
        isTimestampShaped(text) || opensWithThreadMeta(text)
    }

    private static func opensWithThreadMeta(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("replied to a thread")
            || lowered.hasPrefix("started a thread")
    }

    /// Subtrees that decorate a message rather than say it: the author
    /// header, timestamps (a visible short form plus a hidden long
    /// form whose only marking is its date-shaped text), reactions,
    /// embeds, and action buttons.
    private static func isExcluded<Node: ChatAccessibilityNode>(
        _ node: Node
    ) -> Bool {
        if node.subrole == "AXTimeGroup" { return true }
        if let dom = node.domIdentifier,
            dom.contains("message-username")
                || dom.contains("message-timestamp")
                || dom.contains("message-reply-context")
                || dom.contains("message-reactions")
                || dom.contains("message-accessories")
        {
            return true
        }
        if node.role == "AXButton" || node.role == "AXImage"
            || node.role == "AXCheckBox"
        {
            return true
        }
        if let text = node.textValue ?? node.axDescription,
            isTimestampShaped(text)
        {
            return true
        }
        return false
    }

    /// Whether an item's subtree holds a text input — the reply
    /// composer that chat apps render inside the message list.
    private static func containsComposer<Node: ChatAccessibilityNode>(
        _ item: Node
    ) -> Bool {
        firstDescendant(of: item) {
            $0.role == "AXTextArea" || $0.role == "AXTextField"
        } != nil
    }

    /// Whether text is a bare timestamp line. Discord writes
    /// "Yesterday at 8:17 PM" and "Wednesday, August 5, 2026 at
    /// 8:17 PM"; Slack writes "[1:21 PM]" and bare "1:21 PM".
    static func isTimestampShaped(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(#/^[\w, ]+ at \d{1,2}:\d{2}\s?(?:AM|PM)$/#) {
            return true
        }
        return trimmed.contains(#/^\[?\d{1,2}:\d{2}(?:\s?(?:AM|PM))?\]?$/#)
    }

    // MARK: - Traversal

    private static func firstDescendant<Node: ChatAccessibilityNode>(
        of node: Node, depth: Int = 0,
        where matches: (Node) -> Bool
    ) -> Node? {
        guard depth <= findDepthLimit else { return nil }
        if matches(node) { return node }
        for child in node.children {
            if let found = firstDescendant(
                of: child, depth: depth + 1, where: matches)
            {
                return found
            }
        }
        return nil
    }

    /// Concatenate static text in traversal order. Chat fragments
    /// carry their own spacing ("Glad you're here, " + "Velgrim"),
    /// so fragments join without separators.
    private static func gatherText<Node: ChatAccessibilityNode>(
        under node: Node, depth: Int = 0
    ) -> String {
        guard depth <= findDepthLimit else { return "" }
        guard depth == 0 || !isExcluded(node) else { return "" }
        var text = ""
        if node.role == "AXStaticText", let value = node.textValue {
            text += value
        }
        for child in node.children {
            text += gatherText(under: child, depth: depth + 1)
        }
        return text
    }

    private static func collectedText<Node: ChatAccessibilityNode>(
        under node: Node?
    ) -> String? {
        guard let node else { return nil }
        let text = normalized(gatherText(under: node))
        return text.isEmpty ? nil : text
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }
}
