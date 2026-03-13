import AppKit
import WebKit

/// A window that hosts a WKWebView for onboarding, account, and
/// session recovery flows. The web view loads pages from the user's
/// FreeFlowService zone and communicates with native code via the
/// OnboardingBridge message handler.
///
/// The same window is reused for all web-based flows: initial
/// onboarding, add-email, sign-in, and session recovery. Call
/// `navigate(to:)` to load a different page without recreating the
/// window.
final class OnboardingWindow: NSWindow, WKNavigationDelegate {

    private static func log(_ msg: String) {
        NSLog("[OnboardingWindow] %@", msg)
    }

    /// The web view that displays zone-hosted pages.
    let webView: WKWebView

    /// The web view configuration, retained so the bridge message
    /// handler can be added before the first page load.
    private let webConfig: WKWebViewConfiguration

    /// Name of the WKScriptMessageHandler channel. JavaScript calls
    /// `window.webkit.messageHandlers.freeflow.postMessage(...)` to send
    /// messages to native code.
    static let bridgeHandlerName = "freeflow"

    /// Default window size for onboarding (matches the zone's
    /// onboarding page design at 480px width).
    private static let defaultSize = NSSize(width: 480, height: 720)

    /// Height of the transparent drag handle at the top of the window.
    private static let dragHandleHeight: CGFloat = 76

    // MARK: - Initialization

    /// Create a new onboarding window.
    ///
    /// The window is centered on screen, non-resizable, and has a
    /// title bar with close button but no minimize or zoom. It becomes
    /// the key window when shown.
    ///
    /// - Parameter bridge: The script message handler that receives
    ///   bridge messages from JavaScript. Pass an `OnboardingBridge`
    ///   instance. If nil, no bridge is registered (useful for testing).
    init(bridge: WKScriptMessageHandler? = nil) {
        let config = WKWebViewConfiguration()

        // Allow communication between the web page and native code.
        if let bridge {
            config.userContentController.add(bridge, name: Self.bridgeHandlerName)
        }

        self.webConfig = config
        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let contentRect = NSRect(
            origin: .zero,
            size: Self.defaultSize
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        backgroundColor = NSColor(
            red: 0xEE / 255.0, green: 0xEC / 255.0, blue: 0xEB / 255.0, alpha: 1.0)

        // Use a container view so we can layer the drag handle on top
        // of the web view. The drag handle is a transparent view that
        // covers the top of the window, providing a generous drag
        // target beyond the tiny hidden title bar.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragHandle = WindowDragHandleView(
            frame: NSRect(
                x: 0,
                y: Self.defaultSize.height - Self.dragHandleHeight,
                width: Self.defaultSize.width,
                height: Self.dragHandleHeight
            )
        )
        dragHandle.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragHandle)

        contentView = container
        positionRight()

        webView.navigationDelegate = self
    }

    /// Position the window on the right side of the screen, vertically
    /// centered, with a comfortable margin from the edge.
    private func positionRight() {
        guard let screen = NSScreen.main else {
            center()
            return
        }
        let visible = screen.visibleFrame
        let margin: CGFloat = 96
        let x = visible.maxX - frame.width - margin
        let y = visible.maxY - frame.height - margin
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Close override

    /// Override close to hide instead of destroy. The close button (×)
    /// sends `close()`, which would deallocate the window while
    /// `OnboardingController` still holds a reference. Using `orderOut`
    /// keeps the window alive so it can be re-presented via the menu
    /// bar "Open Setup…" item.
    override func close() {
        orderOut(nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Self.log("didStartProvisionalNavigation: \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Self.log("didFinish: \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Self.log("didFail: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Self.log(
            "didFailProvisionalNavigation: \(error.localizedDescription) url=\(webView.url?.absoluteString ?? "nil")"
        )
    }

    // MARK: - Navigation

    /// Load a page at the given URL in the web view.
    ///
    /// Use this to navigate to onboarding, account, or sign-in pages
    /// on the zone. The URL should be a full URL including the zone
    /// base (e.g. `https://zone.example.com/onboarding/?token=abc`).
    func navigate(to url: URL) {
        Self.log("navigate(to: \(url.absoluteString))")
        NSLog("[OnboardingWindow] navigate(to:) \(url.absoluteString)")
        let request = URLRequest(url: url)
        webView.load(request)
    }

    /// Load a page by constructing a URL from a base URL and path.
    ///
    /// - Parameters:
    ///   - baseURL: The zone base URL (e.g. `https://zone.example.com`).
    ///   - path: The path to load (e.g. `/onboarding/?token=abc`).
    func navigate(baseURL: String, path: String) {
        let combined = "\(baseURL)\(path)"
        Self.log("navigate(baseURL:path:) base=\(baseURL) path=\(path) combined=\(combined)")
        NSLog(
            "[OnboardingWindow] navigate(baseURL:path:) base=%@ path=%@ combined=%@", baseURL, path,
            combined)
        guard let url = URL(string: combined) else {
            Self.log("navigate(baseURL:path:) failed to create URL from: \(combined)")
            return
        }
        navigate(to: url)
    }

    // MARK: - Bundled pages

    /// Load a bundled HTML page from the app bundle by resource name.
    ///
    /// The page must be a self-contained HTML file (all CSS and JS
    /// inlined) shipped in the app bundle. Optional query parameters
    /// are appended to the file URL so the page JS can read them with
    /// `URLSearchParams(window.location.search)`.
    ///
    /// - Parameters:
    ///   - name: The resource name without extension (e.g. "onboarding",
    ///     "add-email", "sign-in").
    ///   - queryString: Optional query string without the leading `?`,
    ///     e.g. `"token=abc"` or `"variant=grace"`.
    func loadBundledPage(_ name: String, queryString: String? = nil) {
        guard
            let htmlURL = Bundle.main.url(
                forResource: name,
                withExtension: "html"
            )
        else {
            Self.log("\(name).html not found in bundle")
            return
        }

        var fileURL = htmlURL
        if let queryString, !queryString.isEmpty {
            var components = URLComponents(url: htmlURL, resolvingAgainstBaseURL: false)
            components?.query = queryString
            fileURL = components?.url ?? htmlURL
        }

        Self.log("loadBundledPage(\(name)): \(fileURL.absoluteString)")
        webView.loadFileURL(
            fileURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
    }

    /// Load the bundled onboarding HTML page from the app bundle.
    ///
    /// Convenience wrapper around `loadBundledPage(_:queryString:)`.
    ///
    /// - Parameter queryString: Optional query string without the
    ///   leading `?`, e.g. `"token=abc"` or `"skip=connect"`.
    func loadBundledOnboarding(queryString: String? = nil) {
        loadBundledPage("onboarding", queryString: queryString)
    }

    // MARK: - Presentation

    /// Show the window, make it key, and bring it to the front.
    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the window and remove the bridge handler to break any
    /// reference cycles.
    ///
    /// Uses `orderOut` instead of `close` so SwiftUI's lifecycle does
    /// not see "last window closed" and terminate the app. The window
    /// is deallocated when the OnboardingController sets its reference
    /// to nil.
    func dismiss() {
        webConfig.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeHandlerName
        )
        orderOut(nil)
    }
}

// MARK: - Drag Handle

/// A transparent view that enables window dragging from the top area.
///
/// Placed over the web view at the top of the window. Passes through
/// clicks to the web view for any interactive elements underneath, but
/// enables window dragging on the empty background area.
private final class WindowDragHandleView: NSView {

    /// Inset from the left edge to avoid covering the close button.
    private static let closeButtonInset: CGFloat = 68

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim hits in our frame — let everything else fall
        // through to the web view below.
        guard frame.contains(point) else { return nil }

        // Let the close button (top-left corner) receive clicks and
        // show the default arrow cursor instead of the drag hand.
        let localPoint = convert(point, from: superview)
        if localPoint.x < Self.closeButtonInset { return nil }

        return self
    }

    override func resetCursorRects() {
        // Cursor rect excludes the close button area on the left.
        let dragRect = NSRect(
            x: Self.closeButtonInset,
            y: 0,
            width: bounds.width - Self.closeButtonInset,
            height: bounds.height
        )
        addCursorRect(dragRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
