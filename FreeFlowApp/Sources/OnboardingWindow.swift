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
        center()

        webView.navigationDelegate = self
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

    /// Show a local onboarding chooser while waiting for a service URL.
    ///
    /// Displayed on fresh launch before a `freeflow://connect` URL has
    /// been received. This introduces FreeFlow, lets the user choose
    /// between joining with an invite or creating a private server, and
    /// keeps the invite path as an instructional waiting state. The
    /// admin path calls back into the native bridge.
    func loadWaitingPlaceholder() {
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              * { margin: 0; padding: 0; box-sizing: border-box; }
              :root {
                --color-bg: #eeeceb;
                --color-surface: #f9f9f9;
                --color-text: #292929;
                --color-muted: #7a7775;
                --color-border: #ddd9d6;
                --color-light: #a8a4a1;
              }
              body {
                font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                background: var(--color-bg);
                color: var(--color-text);
                display: flex;
                align-items: center;
                justify-content: center;
                height: 100vh;
                padding: 2rem;
                -webkit-user-select: none;
              }
              .shell {
                width: 100%;
                max-width: 360px;
                text-align: center;
              }
              .icon {
                width: 3rem;
                height: 3rem;
                margin: 0 auto 1.5rem;
                border-radius: 999px;
                display: flex;
                align-items: center;
                justify-content: center;
                font-size: 1.5rem;
                background: var(--color-surface);
                border: 1px solid var(--color-border);
              }
              .icon svg {
                width: 1.25rem;
                height: 1.25rem;
              }
              h1 {
                font-size: 1.625rem;
                line-height: 1.384615;
                font-weight: 700;
                margin-bottom: 0.461538em;
                letter-spacing: -0.025em;
              }
              p {
                font-size: 0.9375rem;
                color: var(--color-muted);
                line-height: 1.6;
                margin-bottom: 1.5rem;
              }
              .choice-group {
                display: flex;
                flex-direction: column;
                gap: 0.75rem;
                margin-bottom: 1rem;
              }
              .choice-card {
                width: 100%;
                border: 1px solid var(--color-border);
                border-radius: 16px;
                background: rgba(255, 255, 255, 0.7);
                padding: 1rem 1rem 0.9375rem;
                text-align: left;
                cursor: pointer;
                transition: transform 0.12s ease, border-color 0.12s ease, background 0.12s ease;
              }
              .choice-card:hover {
                transform: translateY(-1px);
                border-color: var(--color-text);
                background: rgba(255, 255, 255, 0.92);
              }
              .choice-title {
                font-size: 0.9375rem;
                font-weight: 600;
                color: var(--color-text);
                margin-bottom: 0.3125rem;
              }
              .choice-copy {
                font-size: 0.8125rem;
                line-height: 1.45;
                color: var(--color-muted);
              }
              .footnote {
                font-size: 0.8125rem;
                line-height: 1.45;
                color: var(--color-light);
              }
              .waiting-actions {
                display: flex;
                flex-direction: column;
                gap: 0.75rem;
                margin-top: 1rem;
              }
              .waiting-link {
                border: none;
                background: none;
                padding: 0;
                font: inherit;
                font-size: 0.875rem;
                color: var(--color-text);
                text-decoration: underline;
                text-underline-offset: 0.15em;
                cursor: pointer;
              }
              .hidden {
                display: none;
              }
            </style>
            </head>
            <body>
              <div class="shell">
                <div id="choice-state">
                  <div class="icon">
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
                      <line x1="4" y1="8" x2="4" y2="16" />
                      <line x1="8" y1="5" x2="8" y2="19" />
                      <line x1="12" y1="3" x2="12" y2="21" />
                      <line x1="16" y1="5" x2="16" y2="19" />
                      <line x1="20" y1="8" x2="20" y2="16" />
                    </svg>
                  </div>
                  <h1>Welcome to FreeFlow</h1>
                  <p>Dictate naturally on your Mac and get polished text back, using your own private FreeFlow server.</p>

                  <div class="choice-group">
                    <button class="choice-card" type="button" id="join-choice">
                      <div class="choice-title">I have an invite link</div>
                      <div class="choice-copy">Join an existing FreeFlow server.</div>
                    </button>

                    <button class="choice-card" type="button" id="admin-choice">
                      <div class="choice-title">Create my FreeFlow server</div>
                      <div class="choice-copy">Sign in to set up your private server and invite your team.</div>
                    </button>
                  </div>
                </div>

                <div id="invite-state" class="hidden">
                  <div class="icon">&#128279;</div>
                  <h1>Open your invite link</h1>
                  <p>Click the invite link you received in your browser. FreeFlow will connect automatically on this Mac.</p>

                  <div class="waiting-actions">
                    <button class="waiting-link" type="button" id="switch-to-admin">Create my own server instead</button>
                  </div>
                </div>
              </div>

              <script>
                (function () {
                  var choiceState = document.getElementById("choice-state");
                  var inviteState = document.getElementById("invite-state");
                  var joinChoice = document.getElementById("join-choice");
                  var switchToAdmin = document.getElementById("switch-to-admin");
                  var adminChoice = document.getElementById("admin-choice");

                  function showInviteState() {
                    if (choiceState) choiceState.classList.add("hidden");
                    if (inviteState) inviteState.classList.remove("hidden");
                  }

                  function openProvisioning() {
                    if (
                      window.webkit &&
                      window.webkit.messageHandlers &&
                      window.webkit.messageHandlers.freeflow
                    ) {
                      window.webkit.messageHandlers.freeflow.postMessage({
                        action: "openProvisioning"
                      });
                    }
                  }

                  if (joinChoice) {
                    joinChoice.addEventListener("click", function () {
                      showInviteState();
                    });
                  }

                  if (switchToAdmin) {
                    switchToAdmin.addEventListener("click", function () {
                      openProvisioning();
                    });
                  }

                  if (adminChoice) {
                    adminChoice.addEventListener("click", function () {
                      openProvisioning();
                    });
                  }
                })();
              </script>
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
