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
///   - accountDetails: { firstName, lastName, company } — Screen A done
///   - submitPayment: { setupIntentId } — card confirmed by Stripe.js
///   - skipPayment: user chose trial without card
///   - openExternal: { url } — open URL in system browser
///
/// Events pushed to the provisioning page:
///   - authStarted: Autonomy Account browser sheet is opening
///   - authComplete: login succeeded, provisioning begins
///   - authError: { message } — login failed or was cancelled
///   - provisioningProgress: { message } — status update during setup
///   - provisioningReady: zone is up, transitioning to onboarding
///   - provisioningError: { message } — setup failed
///   - accountSetup: show Screen A (account details + plan)
///   - creditCard: { clientSecret, publishableKey } — show Screen B
///   - paymentSuccess: card saved successfully
///   - paymentError: { message } — card save failed
@MainActor
final class ProvisioningBridge: NSObject, WKScriptMessageHandler {

    /// The web view to push events back to.
    weak var webView: WKWebView?

    /// Called when the user clicks "Get Started".
    var onGetStarted: (() -> Void)?

    /// Called when the user clicks "Retry" after an error.
    var onRetry: (() -> Void)?

    /// Called when the user submits account details from Screen A.
    /// Parameters: (firstName, lastName, company).
    var onAccountDetails: ((String, String, String?) -> Void)?

    /// Called when Stripe.js confirms a SetupIntent on Screen B.
    /// Parameter: setupIntentId.
    var onSubmitPayment: ((String) -> Void)?

    /// Called when the user skips adding a card on Screen B.
    var onSkipPayment: (() -> Void)?

    /// Called when the page requests opening a URL in the system browser.
    var onOpenExternal: ((URL) -> Void)?

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
        case "accountDetails":
            if let data = body["data"] as? [String: Any],
                let firstName = data["firstName"] as? String,
                let lastName = data["lastName"] as? String
            {
                let company = data["company"] as? String
                onAccountDetails?(firstName, lastName, company)
            }
        case "submitPayment":
            if let data = body["data"] as? [String: Any],
                let setupIntentId = data["setupIntentId"] as? String
            {
                onSubmitPayment?(setupIntentId)
            }
        case "skipPayment":
            onSkipPayment?()
        case "openExternal":
            if let data = body["data"] as? [String: Any],
                let urlString = data["url"] as? String,
                let url = URL(string: urlString)
            {
                onOpenExternal?(url)
            }
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

    // MARK: - Billing screen events

    /// Show Screen A: account details + plan overview.
    func pushAccountSetup() {
        pushEvent(name: "accountSetup")
    }

    /// Show Screen B: credit card entry with Stripe Payment Element.
    ///
    /// - Parameters:
    ///   - clientSecret: The Stripe SetupIntent client secret.
    ///   - publishableKey: The Stripe publishable key.
    func pushCreditCard(clientSecret: String, publishableKey: String) {
        pushEvent(
            name: "creditCard",
            data: [
                "clientSecret": clientSecret,
                "publishableKey": publishableKey,
            ])
    }

    /// Notify the page that the payment method was saved.
    func pushPaymentSuccess() {
        pushEvent(name: "paymentSuccess")
    }

    /// Notify the page that saving the payment method failed.
    func pushPaymentError(message: String) {
        pushEvent(name: "paymentError", data: ["message": message])
    }
}
