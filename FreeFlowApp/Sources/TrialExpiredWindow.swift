import AppKit
import FreeFlowKit
import WebKit

/// A small modal window shown when the user's free trial has expired.
///
/// Displays a message explaining that the trial ended and offers two
/// actions: add a credit card (primary) or dismiss (secondary). The
/// window is always-on-top so the user cannot miss it.
///
/// This is a self-contained HTML window using WKWebView, following
/// the same pattern as BillingWindow and OnboardingWindow.
@MainActor
final class TrialExpiredWindow: NSWindow {

    let webView: WKWebView
    private let webConfig: WKWebViewConfiguration

    static let bridgeHandlerName = "trialExpired"
    private static let defaultSize = NSSize(width: 380, height: 340)

    /// Called when the user clicks "Add credit card".
    var onAddCard: (() -> Void)?

    /// Called when the user clicks "Not now".
    var onDismiss: (() -> Void)?

    init() {
        let config = WKWebViewConfiguration()
        self.webConfig = config
        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let contentRect = NSRect(origin: .zero, size: Self.defaultSize)

        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = self
        container.addSubview(webView)

        contentView = container
        center()

        loadHTML()
        setupBridge()
    }

    private func loadHTML() {
        let html = """
            <!doctype html>
            <html>
            <head>
                <meta charset="utf-8">
                <style>
                    * { margin: 0; padding: 0; box-sizing: border-box; }

                    :root {
                        --color-bg: #eeeceb;
                        --color-surface: #f9f9f9;
                        --color-text: #292929;
                        --color-muted: #7a7775;
                        --color-accent: #292929;
                        --color-accent-hover: #3d3d3d;
                        --color-border: #ddd9d6;
                        --color-border-light: #e8e5e3;
                        --color-white: #ffffff;
                    }

                    body {
                        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
                                     "Helvetica Neue", sans-serif;
                        background: var(--color-bg);
                        color: var(--color-text);
                        display: flex;
                        flex-direction: column;
                        align-items: center;
                        justify-content: center;
                        height: 100vh;
                        padding: 2rem;
                        -webkit-user-select: none;
                        cursor: default;
                    }

                    .icon {
                        font-size: 2rem;
                        margin-bottom: 1.25rem;
                        line-height: 1;
                    }

                    h1 {
                        font-size: 1.25rem;
                        font-weight: 600;
                        margin-bottom: 0.625rem;
                        letter-spacing: -0.01em;
                        text-align: center;
                    }

                    p {
                        font-size: 0.9375rem;
                        color: var(--color-muted);
                        line-height: 1.55;
                        text-align: center;
                        margin-bottom: 0.375rem;
                    }

                    .price {
                        font-size: 0.8125rem;
                        color: var(--color-muted);
                        margin-bottom: 1.5rem;
                        text-align: center;
                    }

                    .btn {
                        display: inline-flex;
                        align-items: center;
                        justify-content: center;
                        padding: 0.75rem 2rem;
                        font-size: 0.9375rem;
                        font-weight: 600;
                        font-family: inherit;
                        color: var(--color-white);
                        background: var(--color-accent);
                        border: none;
                        border-radius: 9999px;
                        cursor: pointer;
                        transition: background 0.15s ease, transform 0.1s ease;
                        width: 100%;
                        max-width: 280px;
                    }

                    .btn:hover { background: var(--color-accent-hover); }
                    .btn:active { transform: scale(0.98); }

                    .dismiss {
                        font-size: 0.8125rem;
                        color: var(--color-muted);
                        cursor: pointer;
                        margin-top: 0.875rem;
                        text-decoration: underline;
                        text-decoration-color: var(--color-border);
                        text-underline-offset: 0.15em;
                        transition: color 0.15s, text-decoration-color 0.15s;
                    }

                    .dismiss:hover {
                        color: var(--color-text);
                        text-decoration-color: var(--color-text);
                    }
                </style>
            </head>
            <body>
                <div class="icon">\u{23F1}</div>
                <h1>Your free trial has ended</h1>
                <p>Add a credit card to keep using FreeFlow. Your server will be restored.</p>
                <div class="price">$75/month + model usage.</div>
                <button class="btn" onclick="addCard()">Add credit card</button>
                <div class="dismiss" onclick="dismiss()">Not now</div>

                <script>
                    function addCard() {
                        window.webkit.messageHandlers.trialExpired.postMessage({ action: 'addCard' });
                    }
                    function dismiss() {
                        window.webkit.messageHandlers.trialExpired.postMessage({ action: 'dismiss' });
                    }
                </script>
            </body>
            </html>
            """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func setupBridge() {
        let handler = TrialExpiredBridgeHandler()
        handler.onAddCard = { [weak self] in
            self?.onAddCard?()
        }
        handler.onDismiss = { [weak self] in
            self?.onDismiss?()
        }
        webConfig.userContentController.add(handler, name: Self.bridgeHandlerName)
    }

    // MARK: - Presentation

    func present() {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        webConfig.userContentController.removeScriptMessageHandler(
            forName: Self.bridgeHandlerName
        )
        orderOut(nil)
    }
}

// MARK: - WKNavigationDelegate

extension TrialExpiredWindow: WKNavigationDelegate {}

// MARK: - Bridge handler

private final class TrialExpiredBridgeHandler: NSObject, WKScriptMessageHandler {

    var onAddCard: (() -> Void)?
    var onDismiss: (() -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else { return }

        Task { @MainActor in
            switch action {
            case "addCard":
                self.onAddCard?()
            case "dismiss":
                self.onDismiss?()
            default:
                break
            }
        }
    }
}
