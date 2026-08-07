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
            // Slack's Threads view needs one more shape: a thread
            // section without its own list, sitting directly inside
            // the aggregate "Threads" list. Searching the aggregate's
            // descendants would land in another thread, but the
            // element the climb just left IS this thread's section —
            // its rows are the messages.
            var previous = composer
            var ancestor = AXElementHelper.elementValue(
                of: kAXParentAttribute, from: composer)
            var hops = 0
            while let current = ancestor, hops < 25, !Task.isCancelled {
                let currentNode = AXChatNode(element: current)
                if ChatMessageTree.isAggregateThreadList(currentNode) {
                    let section = AXChatNode(element: previous)
                    if let message = ChatMessageTree.lastMessage(in: section),
                        !message.blocks.isEmpty
                    {
                        return deliver(message)
                    }
                    // A footer section holds only the composer; its
                    // thread's rows are keyed sibling items.
                    if let footerID = section.domIdentifier,
                        case let rows = ChatMessageTree.threadRows(
                            inAggregate: currentNode, footerID: footerID),
                        !rows.isEmpty,
                        let message = ChatMessageTree.lastMessage(among: rows),
                        !message.blocks.isEmpty
                    {
                        return deliver(message)
                    }
                    #if DEBUG
                        let items = currentNode.children.map {
                            "\($0.role ?? "?"):\($0.domIdentifier?.prefix(50) ?? "")"
                        }.joined(separator: " ")
                        Log.debug(
                            "[ChatRead] aggregate section empty; section=\(section.domIdentifier ?? "nil") items: \(items) shape: \(dumpShape(section))"
                        )
                    #endif
                }
                if let list = ChatMessageTree.messageList(
                    under: currentNode),
                    let message = ChatMessageTree.lastMessage(in: list),
                    !message.blocks.isEmpty
                {
                    return deliver(message)
                }
                previous = current
                ancestor = AXElementHelper.elementValue(
                    of: kAXParentAttribute, from: current)
                hops += 1
            }
            #if DEBUG
                logListInventory(around: composer)
            #endif
            return nil
        }

        private static func deliver(
            _ message: ChatMessageTree.LastMessage
        ) -> ReadableContent {
            #if DEBUG
                // Extraction forensics; logs read content, so DEBUG
                // only — like the capture-sample dump.
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

        #if DEBUG
            /// Render a subtree's shape for miss forensics: roles,
            /// descriptions, DOM ids, and text prefixes.
            private static func dumpShape(
                _ node: AXChatNode, depth: Int = 0, budget: inout Int
            ) -> String {
                guard budget > 0, depth <= 8 else { return "" }
                budget -= 1
                var parts: [String] = []
                let role = node.role ?? "?"
                let desc = node.axDescription.flatMap {
                    $0.isEmpty ? nil : " d=\($0.prefix(40))"
                } ?? ""
                let dom = node.domIdentifier.flatMap {
                    $0.isEmpty ? nil : " id=\($0.prefix(40))"
                } ?? ""
                let text = node.textValue.flatMap {
                    $0.isEmpty ? nil : " t=\($0.prefix(30))"
                } ?? ""
                parts.append(
                    "\(String(repeating: ">", count: depth))\(role)\(desc)\(dom)\(text)"
                )
                for child in node.children {
                    let rendered = dumpShape(
                        child, depth: depth + 1, budget: &budget)
                    if !rendered.isEmpty { parts.append(rendered) }
                }
                return parts.joined(separator: " ")
            }

            private static func dumpShape(_ node: AXChatNode) -> String {
                var budget = 100
                return dumpShape(node, budget: &budget)
            }

            /// On a miss, log every list above the composer so a live
            /// failure names the anchors the locator should match.
            private static func logListInventory(around composer: AXUIElement) {
                var lines: [String] = []
                var ancestor = AXElementHelper.elementValue(
                    of: kAXParentAttribute, from: composer)
                var hops = 0
                while let current = ancestor, hops < 25 {
                    let node = AXChatNode(element: current)
                    let role = node.role ?? "?"
                    let desc = node.axDescription ?? ""
                    if role == "AXList" || !desc.isEmpty {
                        lines.append("hop\(hops) \(role) desc=\"\(desc.prefix(60))\"")
                    }
                    for list in ChatMessageTree.allLists(
                        under: node, limit: 4)
                    {
                        lines.append(
                            "hop\(hops) descendant AXList desc=\"\(list.axDescription?.prefix(60) ?? "")\" items=\(list.children.count)"
                        )
                    }
                    ancestor = AXElementHelper.elementValue(
                        of: kAXParentAttribute, from: current)
                    hops += 1
                }
                Log.debug(
                    "[ChatRead] no message list; inventory: \(lines.joined(separator: " | "))"
                )
            }
        #endif

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
