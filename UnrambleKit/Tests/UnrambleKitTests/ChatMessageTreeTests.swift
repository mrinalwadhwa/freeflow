import Foundation
import Testing

@testable import UnrambleKit

/// Fixture node mirroring the shapes Discord's live tree exposes.
private struct Node: ChatAccessibilityNode {
    var role: String?
    var subrole: String?
    var axDescription: String?
    var domIdentifier: String?
    var textValue: String?
    var children: [Node] = []
}

private func text(_ value: String) -> Node {
    Node(role: "AXStaticText", textValue: value)
}

private func group(
    dom: String? = nil, desc: String? = nil, _ children: [Node] = []
) -> Node {
    Node(
        role: "AXGroup", axDescription: desc, domIdentifier: dom,
        children: children)
}

/// One message item shaped like Discord's `chat-messages-*` groups.
private func message(
    id: String, author: String? = nil, reply: String? = nil,
    paragraphs: [String]
) -> Node {
    var children: [Node] = []
    if let author {
        children.append(
            group(dom: "message-username-\(id)", [text(author)]))
        children.append(
            Node(
                role: "AXGroup", subrole: "AXTimeGroup",
                domIdentifier: "message-timestamp-\(id)",
                children: [text("Yesterday at 8:17 PM")]))
    }
    if let reply {
        children.append(
            group(dom: "message-reply-context-\(id)", desc: reply))
    }
    children.append(
        group(dom: "message-content-\(id)", paragraphs.map { group([text($0)]) }))
    return group(dom: "chat-messages-1234-\(id)", children)
}

private func window(list: Node) -> Node {
    group([group([group([list])])])
}

@Suite("Chat message tree")
struct ChatMessageTreeTests {

    @Test("The described message list is found under the root")
    func findsDescribedList() {
        let list = Node(
            role: "AXList", subrole: "AXContentList",
            axDescription: "Messages in general",
            children: [])
        let root = window(list: list)
        let found = ChatMessageTree.messageList(under: root)
        #expect(found?.axDescription == "Messages in general")
    }

    @Test("An undescribed list is not the message list")
    func ignoresOtherLists() {
        let channels = Node(
            role: "AXList", axDescription: "Channels", children: [])
        #expect(ChatMessageTree.messageList(under: window(list: channels)) == nil)
    }

    @Test("The last message's author and text are extracted")
    func extractsLastMessage() {
        let list = Node(
            role: "AXList", axDescription: "Messages in general",
            children: [
                message(id: "1", author: "arthur360", paragraphs: ["Hi all."]),
                message(
                    id: "2", author: "Velgrim",
                    paragraphs: ["Glad you're here.", "Take a look at the docs."]),
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.attribution == "Velgrim")
        #expect(last?.blocks == ["Glad you're here.", "Take a look at the docs."])
    }

    @Test("A grouped message takes its author from the earlier sibling")
    func groupedMessageInheritsAuthor() {
        let list = Node(
            role: "AXList", axDescription: "Messages in general",
            children: [
                message(id: "1", author: "mrinal", paragraphs: ["First thought."]),
                message(id: "2", paragraphs: ["Second thought."]),
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.attribution == "mrinal")
        #expect(last?.blocks == ["Second thought."])
    }

    @Test("A reply header supersedes the bare username")
    func replyContextWins() {
        let list = Node(
            role: "AXList", axDescription: "Messages in general",
            children: [
                message(
                    id: "1", author: "mrinal",
                    reply: "mrinal replying to arthur360",
                    paragraphs: ["Agreed, let's do it."]),
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.attribution == "mrinal replying to arthur360")
    }

    @Test("Timestamps inside the content are not spoken")
    func timestampsExcluded() {
        // Discord nests a visible short timestamp (AXTimeGroup) and a
        // hidden long form inside a system message's content.
        let content = group(dom: "message-content-9", [
            group([
                text("Glad you're here, "),
                Node(role: "AXLink", axDescription: "Velgrim",
                     children: [text("Velgrim")]),
                text("."),
                group([
                    Node(role: "AXGroup", subrole: "AXTimeGroup",
                         children: [text("Yesterday at 8:17 PM")])
                ]),
                group(dom: "_r_86r_", [
                    text("Wednesday, August 5, 2026 at 8:17 PM")
                ]),
            ]),
            Node(role: "AXButton",
                 children: [text("Wave to say hi!")]),
        ])
        let list = Node(
            role: "AXList", axDescription: "Messages in general",
            children: [group(dom: "chat-messages-1234-9", [content])])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.blocks == ["Glad you're here, Velgrim."])
    }

    @Test("A trailing memberless item falls back to earlier messages")
    func skipsEmptyTrailingItems() {
        let list = Node(
            role: "AXList", axDescription: "Messages in general",
            children: [
                message(id: "1", author: "smc", paragraphs: ["Ship it."]),
                group(dom: "chat-messages-1234-divider", []),
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.attribution == "smc")
        #expect(last?.blocks == ["Ship it."])
    }

    @Test("Timestamp-shaped lines are recognized")
    func timestampShapes() {
        #expect(ChatMessageTree.isTimestampShaped("Yesterday at 8:17 PM"))
        #expect(
            ChatMessageTree.isTimestampShaped(
                "Wednesday, August 5, 2026 at 8:17 PM"))
        #expect(!ChatMessageTree.isTimestampShaped("Meet me at the office"))
        #expect(!ChatMessageTree.isTimestampShaped("Glad you're here."))
    }

    @Test("Items without content wrappers collect structurally")
    func slackShapedItemFallsBack() {
        // Slack exposes no message-content DOM ids; the item's text
        // collects with the same decoration skips.
        let item = group([
            Node(role: "AXGroup", subrole: "AXTimeGroup",
                 children: [text("2:14 PM")]),
            group([text("The deploy finished clean.")]),
        ])
        let list = Node(
            role: "AXList", axDescription: "Messages in channel general",
            children: [item])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.blocks == ["The deploy finished clean."])
        #expect(last?.attribution == nil)
    }
}
