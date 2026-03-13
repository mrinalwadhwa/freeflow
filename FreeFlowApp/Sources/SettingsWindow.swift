import AppKit
import WebKit

/// A window that hosts a WKWebView for the settings page.
///
/// Follows the same pattern as `OnboardingWindow` but with a smaller
/// size appropriate for settings. The web view loads a self-contained
/// settings page from the app bundle and communicates with native code
/// via the same bridge message handler protocol.
///
/// The window is reused across open/close cycles. Call `present()` to
/// show and `dismiss()` to hide without destroying.
final class SettingsWindow: NSWindow, WKNavigationDelegate {

    private static func log(_ msg: String) {
        NSLog("[SettingsWindow] %@", msg)
    }

    /// The web view that displays the settings page.
    let webView: WKWebView

    /// The web view configuration, retained so the bridge message
    /// handler can be removed on dismiss to break reference cycles.
    private let webConfig: WKWebViewConfiguration

    /// Name of the WKScriptMessageHandler channel. Uses the same
    /// "freeflow" channel as onboarding so the bridge.js wrapper works
    /// without modification.
    static let bridgeHandlerName = "freeflow"

    /// Window size for settings (narrower and shorter than onboarding).
    private static let defaultSize = NSSize(width: 480, height: 760)

    /// Height of the transparent drag handle at the top of the window.
    private static let dragHandleHeight: CGFloat = 52

    // MARK: - Initialization

    /// Create a new settings window.
    ///
    /// The window is centered on screen, non-resizable, and has a
    /// transparent title bar with a close button. It floats above
    /// other windows when shown.
    ///
    /// - Parameter bridge: The script message handler that receives
    ///   bridge messages from JavaScript. If nil, no bridge is
    ///   registered (useful for testing).
    init(bridge: WKScriptMessageHandler? = nil) {
        let config = WKWebViewConfiguration()

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
        isReleasedWhenClosed = false

        // Use a container view so we can layer a drag handle on top
        // of the web view, providing a generous drag target beyond
        // the tiny hidden title bar.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragHandle = SettingsDragHandleView(
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
        center()

        webView.navigationDelegate = self
    }

    // MARK: - Close override

    /// Callback invoked when the window is closed via the title bar
    /// close button. Set by `SettingsController` to stop mic preview.
    var onClose: (() -> Void)?

    /// Override close to hide instead of destroy. The close button
    /// sends `close()`, which would deallocate the window. Using
    /// `orderOut` keeps the window alive for reuse. Calls `onClose`
    /// first so the controller can stop mic preview.
    override func close() {
        onClose?()
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

    /// Load the settings page from the zone.
    ///
    /// - Parameters:
    ///   - baseURL: The zone base URL (e.g. `https://zone.example.com`).
    ///   - path: The path to load (defaults to `/settings/`).
    func navigate(baseURL: String, path: String = "/settings/") {
        let combined = "\(baseURL)\(path)"
        guard let url = URL(string: combined) else {
            Self.log("navigate failed to create URL from: \(combined)")
            return
        }
        Self.log("navigate(to: \(url.absoluteString))")
        let request = URLRequest(url: url)
        webView.load(request)
    }

    // MARK: - Bundled settings

    /// Load the bundled settings HTML page from the app bundle.
    ///
    /// The settings page is self-contained (all CSS and JS inlined)
    /// and does not depend on a zone server. All data flows through
    /// the native bridge.
    func loadBundledSettings() {
        guard
            let htmlURL = Bundle.main.url(
                forResource: "settings",
                withExtension: "html"
            )
        else {
            Self.log("settings.html not found in bundle")
            return
        }

        Self.log("loadBundledSettings: \(htmlURL.absoluteString)")
        webView.loadFileURL(
            htmlURL,
            allowingReadAccessTo: htmlURL.deletingLastPathComponent()
        )
    }

    // MARK: - Presentation

    /// Show the window, make it key, and bring it to the front.
    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide the window and remove the bridge handler to break any
    /// reference cycles.
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
/// Placed over the web view at the top of the settings window. Passes
/// through clicks to the web view for interactive elements underneath,
/// but enables window dragging on the empty background area.
private final class SettingsDragHandleView: NSView {

    /// Inset from the left edge to avoid covering the close button.
    private static let closeButtonInset: CGFloat = 68

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }

        // Let the close button (top-left corner) receive clicks and
        // show the default arrow cursor instead of the drag hand.
        let localPoint = convert(point, from: superview)
        if localPoint.x < Self.closeButtonInset { return nil }

        return self
    }

    override func resetCursorRects() {
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
