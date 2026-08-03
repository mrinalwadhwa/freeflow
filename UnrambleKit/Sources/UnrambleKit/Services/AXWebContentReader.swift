import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

/// Reads a browser page's main content through the Accessibility API.
///
/// Walks the focused window to the web area, then to the ARIA main
/// landmark (see `WebContentTree` for fallbacks), and collects tagged
/// text segments. Reads are passive: nothing about the page's focus,
/// selection, or scroll position changes.
///
/// The walk runs as a detached operation so a deadline returns promptly
/// even when the walk is deep inside synchronous AX calls; the abandoned
/// walk is cancelled and unwinds at its per-node cancellation checks.
public struct AXWebContentReader: WebContentReading {

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 1.8) {
        self.timeout = timeout
    }

    public func readMainContent(processIdentifier: Int32) async
        -> ReadableContent?
    {
        #if canImport(ApplicationServices)
            let pid = processIdentifier
            let operation = DetachedOperation { () -> ReadableContent? in
                await Self.readPage(pid: pid)
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
        private static func readPage(pid: Int32) async -> ReadableContent? {
            let app = AXElementHelper.applicationElement(pid: pid)
            // Chromium publishes no page content until an assistive
            // client announces itself; these attributes are that signal
            // (verified against Chrome: without them the tree holds only
            // browser chrome). Safari ignores them. The tree then builds
            // asynchronously, so the web-area search retries below.
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(
                app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard let window = AXElementHelper.focusedWindow(of: app) else {
                return nil
            }
            var webArea = WebContentTree.firstDescendant(
                of: AXWebNode(element: window), role: "AXWebArea")
            var retriesLeft = 4
            while webArea == nil, retriesLeft > 0, !Task.isCancelled {
                retriesLeft -= 1
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return nil }
                webArea = WebContentTree.firstDescendant(
                    of: AXWebNode(element: window), role: "AXWebArea")
            }
            guard let webArea, !Task.isCancelled else { return nil }
            let main = WebContentTree.mainRegion(of: webArea)
            guard !Task.isCancelled else { return nil }
            let segments = WebContentTree.segments(under: main)
            guard !Task.isCancelled, !segments.isEmpty else { return nil }
            return ReadableContent(segments: segments)
        }
    #endif
}

#if canImport(ApplicationServices)
    /// Adapt a live AXUIElement to the traversal abstraction. Every
    /// property read is IPC to the target application.
    private struct AXWebNode: WebAccessibilityNode {
        let element: AXUIElement

        var role: String? {
            AXElementHelper.role(of: element)
        }

        var subrole: String? {
            AXElementHelper.subrole(of: element)
        }

        var textValue: String? {
            AXElementHelper.stringValue(of: kAXValueAttribute, from: element)
        }

        var children: [AXWebNode] {
            (AXElementHelper.children(of: element) ?? [])
                .map { AXWebNode(element: $0) }
        }
    }
#endif
