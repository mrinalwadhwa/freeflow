import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Reads the last message of the chat panel the user is replying in.
///
/// Applies only when the frontmost app is a known chat app and focus
/// is in a text composer — the reply box is the trigger. The walk goes
/// up from the composer and searches each enclosing ancestor for a
/// described message list, so a thread reply box finds the thread's
/// own messages, not the channel behind it. Reads are passive.
public struct ChatLastMessageContentSource: ContentSourceProviding {

    /// Chat apps whose message region announces itself through an
    /// ARIA "messages" label. Discord's tree is live-verified; Slack
    /// labels its message region the same standards-based way.
    static let chatBundleIDs: Set<String> = [
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
    ]

    /// Focused roles that count as a composer.
    static let composerRoles: Set<String> = ["AXTextArea", "AXTextField"]

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1.8) {
        self.timeout = timeout
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        guard Self.chatBundleIDs.contains(context.bundleID) else {
            return nil
        }
        #if canImport(ApplicationServices)
            guard let pid = context.processIdentifier else { return nil }
            let operation = DetachedOperation { () -> ReadableContent? in
                await Self.readLastMessage(pid: pid)
            }
            let outcome = await operation.outcome(timeout: timeout)
            guard case let .completed(content) = outcome else {
                operation.task.cancel()
                return nil
            }
            return content
        #else
            return nil
        #endif
    }

    #if canImport(ApplicationServices)
        private static func readLastMessage(pid: Int32) async
            -> ReadableContent?
        {
            let app = AXElementHelper.applicationElement(pid: pid)
            // Chromium publishes no content until an assistive client
            // announces itself; the tree then builds asynchronously,
            // so the composer lookup retries briefly.
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var composer = focusedComposer(of: app)
            var retriesLeft = 4
            while composer == nil, retriesLeft > 0, !Task.isCancelled {
                retriesLeft -= 1
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return nil }
                composer = focusedComposer(of: app)
            }
            guard let composer, !Task.isCancelled else { return nil }

            // Nearest enclosing ancestor whose subtree holds a message
            // list wins: a thread panel's reply box resolves to the
            // thread's list before the channel's ever enters the walk.
            var ancestor = AXElementHelper.elementValue(
                of: kAXParentAttribute, from: composer)
            var hops = 0
            while let current = ancestor, hops < 25, !Task.isCancelled {
                if let list = ChatMessageTree.messageList(
                    under: AXChatNode(element: current)),
                    let message = ChatMessageTree.lastMessage(in: list),
                    !message.blocks.isEmpty
                {
                    #if DEBUG
                        // Extraction forensics; logs read content, so
                        // DEBUG only — like the capture-sample dump.
                        Log.debug(
                            "[ChatRead] attribution=\(message.attribution ?? "nil") blocks=\(message.blocks)"
                        )
                    #endif
                    return ReadableContent(
                        attribution: message.attribution,
                        segments: message.blocks.map {
                            .init(kind: .prose, text: $0)
                        })
                }
                ancestor = AXElementHelper.elementValue(
                    of: kAXParentAttribute, from: current)
                hops += 1
            }
            return nil
        }

        private static func focusedComposer(of app: AXUIElement)
            -> AXUIElement?
        {
            guard
                let focused = AXElementHelper.elementValue(
                    of: kAXFocusedUIElementAttribute, from: app),
                let role = AXElementHelper.role(of: focused),
                composerRoles.contains(role)
            else { return nil }
            return focused
        }
    #endif
}

#if canImport(ApplicationServices)
    /// Adapt a live AXUIElement to the chat traversal abstraction.
    /// Every property read is IPC to the chat app.
    private struct AXChatNode: ChatAccessibilityNode {
        let element: AXUIElement

        var role: String? {
            AXElementHelper.role(of: element)
        }

        var subrole: String? {
            AXElementHelper.subrole(of: element)
        }

        var axDescription: String? {
            AXElementHelper.stringValue(
                of: kAXDescriptionAttribute, from: element)
        }

        var domIdentifier: String? {
            AXElementHelper.stringValue(of: "AXDOMIdentifier", from: element)
        }

        var textValue: String? {
            AXElementHelper.stringValue(of: kAXValueAttribute, from: element)
        }

        var children: [AXChatNode] {
            (AXElementHelper.children(of: element) ?? [])
                .map { AXChatNode(element: $0) }
        }
    }
#endif
