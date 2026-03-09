import AppKit
import WebKit

/// A window that hosts a WKWebView for onboarding, account, and
/// session recovery flows. The web view loads pages from the user's
/// VoiceService zone and communicates with native code via the
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
    /// `window.webkit.messageHandlers.voice.postMessage(...)` to send
    /// messages to native code.
    static let bridgeHandlerName = "voice"

    /// Default window size for onboarding (matches the zone's
    /// onboarding page design at 480px width).
    private static let defaultSize = NSSize(width: 480, height: 640)

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
        contentView = webView
        center()

        webView.navigationDelegate = self
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
        guard let url = URL(string: combined) else {
            Self.log("navigate(baseURL:path:) failed to create URL from: \(combined)")
            return
        }
        navigate(to: url)
    }

    // MARK: - Placeholder

    /// Show a local placeholder page while waiting for an invite link.
    ///
    /// Displayed on fresh launch before a `voice://connect` URL has
    /// been received. The page shows a brief instruction so the user
    /// knows the app is waiting for their invite link click.
    func loadWaitingPlaceholder() {
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              * { margin: 0; padding: 0; box-sizing: border-box; }
              body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                background: #EEECEB;
                color: #292929;
                display: flex;
                flex-direction: column;
                align-items: center;
                justify-content: center;
                height: 100vh;
                padding: 2rem;
                text-align: center;
                -webkit-user-select: none;
              }
              .icon { font-size: 2.5rem; margin-bottom: 1.5rem; }
              h1 { font-size: 1.25rem; font-weight: 600; margin-bottom: 0.75rem; }
              p { font-size: 0.9375rem; color: #7A7775; line-height: 1.5; }
            </style>
            </head>
            <body>
              <div class="icon">&#9993;</div>
              <h1>Click your invite link</h1>
              <p>Open the invite link you received to get started.</p>
            </body>
            </html>
            """
        webView.loadHTMLString(html, baseURL: nil)
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
