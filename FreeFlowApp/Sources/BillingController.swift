import AppKit
import FreeFlowKit
import WebKit

/// Standalone billing controller for adding a credit card.
///
/// Used from the People page when the user doesn't have a credit card
/// on file. Shows a simple window with a Stripe card form. On success,
/// dismisses and invokes the completion callback.
///
/// This is simpler than `ProvisioningController` because the user is
/// already signed in with a valid Autonomy token.
@MainActor
final class BillingController {

    private let keychain: KeychainService
    private var window: BillingWindow?
    private var bridge: BillingBridge?
    private var autonomyClient: AutonomyClient?

    /// Called when the user successfully adds a credit card.
    var onComplete: (() -> Void)?

    /// Called when the user dismisses without adding a card.
    var onCancel: (() -> Void)?

    // MARK: - Initialization

    init(keychain: KeychainService = KeychainService()) {
        self.keychain = keychain
    }

    // MARK: - Window management

    /// Show the billing window and start the card collection flow.
    func showWindow() {
        guard window == nil else {
            window?.present()
            return
        }

        let billingBridge = BillingBridge()
        let win = BillingWindow(bridge: billingBridge)
        billingBridge.webView = win.webView

        // Wire bridge actions
        billingBridge.onReady = { [weak self] in
            self?.startBillingFlow()
        }

        billingBridge.onSubmitPayment = { [weak self] setupIntentId in
            self?.confirmPayment(setupIntentId: setupIntentId)
        }

        billingBridge.onSkip = { [weak self] in
            self?.dismissWindow()
            self?.onCancel?()
        }

        billingBridge.onClose = { [weak self] in
            self?.dismissWindow()
            self?.onCancel?()
        }

        bridge = billingBridge
        window = win

        loadBillingHTML()
        win.present()
    }

    /// Dismiss the billing window.
    func dismissWindow() {
        window?.dismiss()
        window = nil
        bridge = nil
        autonomyClient = nil
    }

    // MARK: - Billing flow

    private func startBillingFlow() {
        Task {
            do {
                guard let token = keychain.autonomyToken() else {
                    Log.debug("[BillingController] No Autonomy token available")
                    bridge?.pushError(message: "Not signed in. Please restart the app.")
                    return
                }

                let client = AutonomyClient(token: token)
                self.autonomyClient = client

                // Create a Stripe SetupIntent
                bridge?.pushLoading()
                let setupInfo = try await client.createSetupIntent()

                // Push the Stripe info to the web view
                bridge?.pushStripeReady(
                    clientSecret: setupInfo.clientSecret,
                    publishableKey: setupInfo.publishableKey
                )
            } catch {
                Log.debug("[BillingController] SetupIntent failed: \(error)")
                bridge?.pushError(
                    message: "Could not set up card form. Please try again later."
                )
            }
        }
    }

    private func confirmPayment(setupIntentId: String) {
        Task {
            do {
                guard let client = autonomyClient else {
                    bridge?.pushPaymentError(message: "Session expired. Please try again.")
                    return
                }

                try await client.confirmPayment(setupIntentId: setupIntentId)

                // Success!
                bridge?.pushPaymentSuccess()

                // Brief delay to show success state
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                dismissWindow()
                onComplete?()
            } catch {
                Log.debug("[BillingController] Payment confirmation failed: \(error)")
                bridge?.pushPaymentError(
                    message: "Could not save card. Please try again."
                )
            }
        }
    }

    // MARK: - HTML loading

    private func loadBillingHTML() {
        guard let htmlURL = Bundle.main.url(forResource: "billing", withExtension: "html") else {
            Log.debug("[BillingController] billing.html not found in bundle")
            return
        }
        window?.webView.loadFileURL(
            htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
    }
}

// MARK: - BillingBridge

/// Bridge for the billing HTML page.
@MainActor
final class BillingBridge: NSObject, WKScriptMessageHandler {

    weak var webView: WKWebView?

    var onReady: (() -> Void)?
    var onSubmitPayment: ((_ setupIntentId: String) -> Void)?
    var onSkip: (() -> Void)?
    var onClose: (() -> Void)?

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        Task { @MainActor in
            self.handleMessage(message)
        }
    }

    private func handleMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else {
            return
        }

        let data = body["data"] as? [String: Any] ?? [:]

        switch action {
        case "ready":
            onReady?()

        case "submitPayment":
            if let setupIntentId = data["setupIntentId"] as? String {
                onSubmitPayment?(setupIntentId)
            }

        case "skip":
            onSkip?()

        case "close":
            onClose?()

        default:
            break
        }
    }

    // MARK: - Push events to JavaScript

    func pushEvent(name: String, data: [String: Any] = [:]) {
        var payload = data
        payload["event"] = name

        guard
            let jsonData = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.fragmentsAllowed]
            ),
            let jsonString = String(data: jsonData, encoding: .utf8)
        else {
            return
        }

        let script = "window.billingBridge && window.billingBridge.onEvent(\(jsonString));"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.debug("[BillingBridge] pushEvent(\(name)) error: \(error)")
            }
        }
    }

    func pushLoading() {
        pushEvent(name: "loading")
    }

    func pushStripeReady(clientSecret: String, publishableKey: String) {
        pushEvent(
            name: "stripeReady",
            data: [
                "clientSecret": clientSecret,
                "publishableKey": publishableKey,
            ])
    }

    func pushError(message: String) {
        pushEvent(name: "error", data: ["message": message])
    }

    func pushPaymentSuccess() {
        pushEvent(name: "paymentSuccess")
    }

    func pushPaymentError(message: String) {
        pushEvent(name: "paymentError", data: ["message": message])
    }
}

// MARK: - BillingWindow

/// A window that hosts a WKWebView for the billing page.
final class BillingWindow: NSWindow, WKNavigationDelegate {

    private static func log(_ msg: String) {
        #if DEBUG
            Log.debug("[BillingWindow] \(msg)")
        #endif
    }

    let webView: WKWebView
    private let webConfig: WKWebViewConfiguration

    static let bridgeHandlerName = "billing"
    private static let defaultSize = NSSize(width: 420, height: 520)
    private static let dragHandleHeight: CGFloat = 40

    init(bridge: WKScriptMessageHandler? = nil) {
        let config = WKWebViewConfiguration()

        if let bridge {
            config.userContentController.add(bridge, name: Self.bridgeHandlerName)
        }

        self.webConfig = config
        self.webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let contentRect = NSRect(origin: .zero, size: Self.defaultSize)

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

        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.autoresizingMask = [.width, .height]

        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragHandle = BillingDragHandleView(
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

    var onClose: (() -> Void)?

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

    // MARK: - Presentation

    func present() {
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

// MARK: - Drag Handle

private final class BillingDragHandleView: NSView {

    private static let closeButtonInset: CGFloat = 68

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }

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
