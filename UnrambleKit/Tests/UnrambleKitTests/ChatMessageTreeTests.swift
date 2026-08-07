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

    @Test("Slack's place-and-kind list labels are matched")
    func slackListLabelsMatch() {
        // Live anchors from Slack's Threads view: no "message" word
        // at all — a "Thread in ..." prefix or a parenthesized kind.
        for desc in [
            "Thread in all-scrappy-sessions (channel, 1 reply)",
            "all-scrappy-sessions (channel)",
        ] {
            let list = Node(role: "AXList", axDescription: desc, children: [])
            #expect(
                ChatMessageTree.messageList(under: window(list: list))?
                    .axDescription == desc)
        }
    }

    @Test("The aggregate Threads list is recognized but never searched")
    func aggregateThreadsList() {
        let aggregate = Node(
            role: "AXList", axDescription: "Threads, no new replies",
            children: [])
        #expect(ChatMessageTree.isAggregateThreadList(aggregate))
        // Not a message list: matching it would read another
        // thread's messages.
        #expect(
            ChatMessageTree.messageList(under: window(list: aggregate)) == nil)
        let section = Node(
            role: "AXGroup", axDescription: "Thread in channel demos")
        #expect(!ChatMessageTree.isAggregateThreadList(section))
    }

    @Test("One wrapper bundling rows and composer still yields the rows")
    func wrapperBundlingRowsAndComposer() {
        // Live failure: a Threads-view section wraps its message
        // rows AND the inline composer in a single child; skipping
        // composer-bearing items wholesale discarded the messages.
        let wrapper = group([
            message(id: "1", author: "Keerthi", paragraphs: ["Here's the link!"]),
            message(id: "2", author: "mrinal", paragraphs: ["Just RSVP'd."]),
            group([
                Node(role: "AXTextArea", axDescription: "Reply"),
                group([text("Also send to #all-scrappy-sessions")]),
            ]),
        ])
        let section = group([wrapper])
        let last = ChatMessageTree.lastMessage(in: section)
        #expect(last?.attribution == "mrinal")
        #expect(last?.blocks == ["Just RSVP'd."])
    }

    @Test("A role badge is stripped from the spoken author")
    func authorBadgeStripped() {
        // Live: Discord tags the thread starter "Original Poster";
        // reading it as the name says "Original Poster" before the
        // message.
        #expect(ChatMessageTree.cleanedAuthor("Keerthi Original Poster")
            == "Keerthi")
        #expect(ChatMessageTree.cleanedAuthor("velgrim BOT") == "velgrim")
        // A badge with no name behind it is not an author.
        #expect(ChatMessageTree.cleanedAuthor("Original Poster") == nil)
        #expect(ChatMessageTree.cleanedAuthor("") == nil)
        // A real name that merely contains a badge word is untouched.
        #expect(ChatMessageTree.cleanedAuthor("Moderator Jones")
            == "Moderator Jones")
    }

    @Test("The Original Poster badge does not become the author")
    func opBadgeMessageAttribution() {
        let list = Node(
            role: "AXList", axDescription: "Messages in general",
            children: [
                Node(
                    role: "AXGroup",
                    domIdentifier: "chat-messages-1-100",
                    children: [
                        group(dom: "message-username-100", [
                            text("Keerthi"), text("Original Poster"),
                        ]),
                        group(dom: "message-content-100", [
                            group([text("Here's the link!")])
                        ]),
                    ]),
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.attribution == "Keerthi")
        #expect(last?.blocks == ["Here's the link!"])
    }

    @Test("An empty thread's placeholder is not a message")
    func emptyThreadPlaceholderExcluded() {
        // Live failure: Discord's empty-thread panel read "Start the
        // conversation!" with attribution "Original Poster". A list
        // whose real messages carry chat-messages ids treats
        // unmarked rows as chrome.
        let list = Node(
            role: "AXList", axDescription: "Messages in build-help",
            children: [
                message(id: "1", author: "arthur360", paragraphs: ["Real one."]),
                group([
                    group([text("Start the conversation!")]),
                    group([text("Be the first to share what you think!")]),
                ]),
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.blocks == ["Real one."])
        // A fully empty thread reads nothing at all.
        let empty = Node(
            role: "AXList", axDescription: "Messages in fresh-thread",
            children: [
                group([
                    group([text("Start the conversation!")]),
                ])
            ])
        // No marked rows: structural fallback still reads — Slack
        // needs it — so the placeholder list is Discord's to filter
        // by its marked sibling, as above.
        #expect(ChatMessageTree.lastMessage(in: empty)?.blocks
            == ["Start the conversation!"])
    }

    @Test("A footer-keyed thread selects its sibling rows")
    func footerKeyedThreadRows() {
        // Live shape: Slack's Threads view flattens a thread into
        // sibling list items — heading, message rows, and a footer
        // (id threads_view_footer-<channel>-<ts>) holding only the
        // composer. The footer's key selects the thread's rows.
        let aggregate = Node(
            role: "AXList", axDescription: "Threads, no new replies",
            children: [
                group(dom: "threads_view_heading-C0AAA-111", [
                    group([text("Thread in #demos")])
                ]),
                group(dom: "threads_view_row-C0AAA-111", [
                    group([text("Other thread's message.")])
                ]),
                group(dom: "threads_view_footer-C0AAA-111", [
                    Node(role: "AXTextArea", axDescription: "Reply")
                ]),
                group(dom: "threads_view_heading-C0BG02-178", [
                    group([text("Thread in #all-scrappy-sessions")])
                ]),
                group(dom: "threads_view_row-C0BG02-178", [
                    group([text("helloooo wanted to share an event.")])
                ]),
                group(dom: "threads_view_row-C0BG02-178-2", [
                    group([text("Just RSVP'd, would love to attend.")])
                ]),
                group(dom: "threads_view_footer-C0BG02-178", [
                    Node(role: "AXTextArea", axDescription: "Reply")
                ]),
            ])
        let rows = ChatMessageTree.threadRows(
            inAggregate: aggregate, footerID: "threads_view_footer-C0BG02-178")
        let last = ChatMessageTree.lastMessage(among: rows)
        #expect(last?.blocks == ["Just RSVP'd, would love to attend."])
        // The other thread's footer selects only its own rows.
        let other = ChatMessageTree.threadRows(
            inAggregate: aggregate, footerID: "threads_view_footer-C0AAA-111")
        #expect(ChatMessageTree.lastMessage(among: other)?.blocks
            == ["Other thread's message."])
        // A non-footer id selects nothing.
        #expect(ChatMessageTree.threadRows(
            inAggregate: aggregate, footerID: "composer").isEmpty)
    }

    @Test("A thread section without its own list reads as an item")
    func sectionWithoutListReadsRows() {
        // Live failure: some Threads-view sections carry no inner
        // AXList; the section's rows are the messages and its last
        // row is the inline composer.
        let section = group([
            message(id: "1", author: "Keerthi", paragraphs: ["Here's the link!"]),
            message(id: "2", author: "mrinal", paragraphs: ["Just RSVP'd."]),
            group([
                Node(role: "AXTextArea", axDescription: "Reply"),
                group([text("Also send to #all-scrappy-sessions")]),
            ]),
        ])
        let last = ChatMessageTree.lastMessage(in: section)
        #expect(last?.attribution == "mrinal")
        #expect(last?.blocks == ["Just RSVP'd."])
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
        // Slack's forms: bracketed and bare clock times.
        #expect(ChatMessageTree.isTimestampShaped("[1:21 PM]"))
        #expect(ChatMessageTree.isTimestampShaped("1:21 PM"))
        #expect(ChatMessageTree.isTimestampShaped("13:05"))
        #expect(!ChatMessageTree.isTimestampShaped("Meet me at the office"))
        #expect(!ChatMessageTree.isTimestampShaped("Glad you're here."))
        #expect(!ChatMessageTree.isTimestampShaped("The ratio is 3:1 now"))
    }

    @Test("Slack timestamp and thread meta blocks are not spoken")
    func slackMetaBlocksExcluded() {
        // Live failure: a Slack read spoke "[1:21 PM]" and
        // "replied to a thread:" before the message.
        let item = group([
            group([text("[1:21 PM]")]),
            group([text("replied to a thread: The deploy plan for Friday")]),
            group([text("Sounds good, let's ship it then.")]),
        ])
        let list = Node(
            role: "AXList", axDescription: "Messages in channel general",
            children: [item])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.blocks == ["Sounds good, let's ship it then."])
    }

    @Test("A wrapper bundling thread meta with the body keeps the body")
    func metaAndBodyInOneWrapperKeepsBody() {
        // Live failure: Slack wraps "replied to a thread: <snippet>"
        // and the message body in one container; the whole message
        // was dropped as meta and the read fell back to the previous
        // message.
        let snippet = "replied to a thread: There are a couple of "
            + "libraries I saw recently that I think are at the "
            + "bleeding edge and have good open licenses...."
        let body1 = "Did a POC."
        let body2 = "Both good calls, both ultimately and sadly a no. "
            + "Ran them against our real corpus with solid ground "
            + "truth and the results were more than clear about it."
        let wrapper = group([
            group([text("[1:21 PM]")]),
            group([text(snippet)]),
            group([text(body1)]),
            group([text(body2)]),
        ])
        let list = Node(
            role: "AXList", axDescription: "Messages in channel general",
            children: [group([wrapper])])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.blocks == [body1, body2])
    }

    @Test("A thread panel's trailing composer item is not the message")
    func composerItemSkipped() {
        // Live failure: Slack's thread panel renders the reply
        // composer as the list's last item; the read spoke its
        // "Also send to the group" checkbox label.
        let composerItem = group([
            Node(role: "AXTextArea", axDescription: "Reply"),
            Node(role: "AXCheckBox", children: []),
            group([text("Also send to the group")]),
        ])
        let list = Node(
            role: "AXList", axDescription: "Message thread",
            children: [
                message(id: "1", author: "Arijeet", paragraphs: ["Did a POC."]),
                composerItem,
            ])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.attribution == "Arijeet")
        #expect(last?.blocks == ["Did a POC."])
    }

    @Test("An inline bracketed timestamp is dropped from a block")
    func inlineBracketTimestampDropped() {
        let item = group([
            group([
                text("[1:21 PM]"),
                text("Sounds good, let's ship it then."),
            ])
        ])
        let list = Node(
            role: "AXList", axDescription: "Messages in channel general",
            children: [item])
        let last = ChatMessageTree.lastMessage(in: list)
        #expect(last?.blocks == ["Sounds good, let's ship it then."])
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
