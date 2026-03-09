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
final class OnboardingWindow: NSWindow {

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
    }

    // MARK: - Navigation

    /// Load a page at the given URL in the web view.
    ///
    /// Use this to navigate to onboarding, account, or sign-in pages
    /// on the zone. The URL should be a full URL including the zone
    /// base (e.g. `https://zone.example.com/onboarding/?token=abc`).
    func navigate(to url: URL) {
        let request = URLRequest(url: url)
        webView.load(request)
    }

    /// Load a page by constructing a URL from a base URL and path.
    ///
    /// - Parameters:
    ///   - baseURL: The zone base URL (e.g. `https://zone.example.com`).
    ///   - path: The path to load (e.g. `/onboarding/?token=abc`).
    func navigate(baseURL: String, path: String) {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            return
        }
        navigate(to: url)
    }

    // MARK: - Presentation

    /// Show the window, make it key, and bring it to the front.
    func present() {
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close the window and remove the bridge handler to break any
    /// reference cycles.
    func dismiss() {
        webConfig.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeHandlerName
        )
        close()
    }
}
