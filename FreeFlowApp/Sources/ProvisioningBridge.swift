import FreeFlowKit
import WebKit

/// Handle messages from the bundled provisioning HTML page in WKWebView.
///
/// JavaScript calls `window.webkit.messageHandlers.freeflow.postMessage(data)`
/// where `data` is a JSON object with an `action` field. The bridge
/// dispatches each action to the registered handler closure.
///
/// To push events back to JavaScript, call `pushEvent(name:data:)` which
/// evaluates `window.freeflowbridge.onEvent(...)` in the web view.
///
/// Actions received from the provisioning page:
///   - getStarted: user clicked the "Get Started" button
///   - retryProvisioning: user clicked "Retry" after an error
///
/// Events pushed to the provisioning page:
///   - authStarted: Autonomy Account browser sheet is opening
///   - authComplete: login succeeded, provisioning begins
///   - authError: { message } — login failed or was cancelled
///   - provisioningProgress: { message } — status update during setup
///   - provisioningReady: zone is up, transitioning to onboarding
///   - provisioningError: { message } — setup failed
@MainActor
final class ProvisioningBridge: NSObject, WKScriptMessageHandler {

    /// The web view to push events back to.
    weak var webView: WKWebView?

    /// Called when the user clicks "Get Started".
    var onGetStarted: (() -> Void)?

    /// Called when the user clicks "Retry" after an error.
    var onRetry: (() -> Void)?

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

        switch action {
        case "getStarted":
            onGetStarted?()
        case "retryProvisioning":
            onRetry?()
        default:
            break
        }
    }

    // MARK: - Push events to JavaScript

    /// Push an event to the provisioning page by calling
    /// `window.freeflowbridge.onEvent(data)`.
    ///
    /// - Parameters:
    ///   - name: The event name (e.g. "authStarted").
    ///   - data: Additional key-value pairs to include in the event object.
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

        let script = "window.freeflowbridge && window.freeflowbridge.onEvent(\(jsonString));"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.debug("[ProvisioningBridge] pushEvent(\(name)) error: \(error)")
            }
        }
    }

    /// Notify the page that the Autonomy Account browser sheet is opening.
    func pushAuthStarted() {
        pushEvent(name: "authStarted")
    }

    /// Notify the page that login succeeded and provisioning is starting.
    func pushAuthComplete() {
        pushEvent(name: "authComplete")
    }

    /// Notify the page that login failed.
    func pushAuthError(message: String) {
        pushEvent(name: "authError", data: ["message": message])
    }

    /// Update the progress message shown during provisioning.
    func pushProvisioningProgress(message: String) {
        pushEvent(name: "provisioningProgress", data: ["message": message])
    }

    /// Notify the page that the zone is ready.
    func pushProvisioningReady() {
        pushEvent(name: "provisioningReady")
    }

    /// Notify the page that provisioning failed.
    func pushProvisioningError(message: String) {
        pushEvent(name: "provisioningError", data: ["message": message])
    }
}
