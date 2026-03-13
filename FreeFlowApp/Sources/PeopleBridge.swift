import Foundation
import FreeFlowKit
import WebKit

/// Handle messages from the people web page running in WKWebView.
///
/// JavaScript calls `window.webkit.messageHandlers.freeflow.postMessage(data)`
/// where `data` is a JSON object with an `action` field. The bridge
/// dispatches each action to the registered handler closure.
///
/// To push events back to JavaScript, call `pushEvent(name:data:)` which
/// evaluates `window.freeflowbridge.onEvent(...)` in the web view.
///
/// Actions received from people page:
///   - getPeopleState: { action }
///   - createInvite: { action, data: { name?, email? } }
///   - revokeInvite: { action, data: { id } }
///   - removePerson: { action, data: { id } }
///   - copyText: { action, data: { text } }
///   - openBilling: { action }
///   - disconnectFromServer: { action }
///   - closePeople: { action }
///
/// Events pushed to people page:
///   - peopleState: { event, hasCreditCard, invites, people, connectedServer, isAdmin, canDisconnect }
///   - inviteCreated: { event, invite }
///   - inviteRevoked: { event, id }
///   - personRemoved: { event, id }
///   - disconnectedFromServer: { event }
///   - actionError: { event, message }
///   - pageError: { event, message }
///   - toast: { event, message }
@MainActor
final class PeopleBridge: NSObject, WKScriptMessageHandler {

    /// The web view to push events back to. Set by the controller
    /// after the window is created.
    weak var webView: WKWebView?

    /// Handler closures for each bridge action. Set by the controller
    /// to wire native services to people page requests.
    var onGetPeopleState: (() -> Void)?
    var onCreateInvite: ((_ name: String?, _ email: String?) -> Void)?
    var onRevokeInvite: ((_ id: Int) -> Void)?
    var onRemovePerson: ((_ id: String) -> Void)?
    var onCopyText: ((_ text: String) -> Void)?
    var onOpenBilling: (() -> Void)?
    var onDisconnectFromServer: (() -> Void)?
    var onClosePeople: (() -> Void)?

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

        // The JS bridge wraps payload fields inside a "data" key:
        //   bridge.send("createInvite", { name: "Alice", email: "alice@example.com" })
        // becomes { action: "createInvite", data: { name: "Alice", email: "alice@example.com" } }.
        let data = body["data"] as? [String: Any] ?? [:]

        switch action {
        case "getPeopleState":
            onGetPeopleState?()

        case "createInvite":
            let name = data["name"] as? String
            let email = data["email"] as? String
            onCreateInvite?(name, email)

        case "revokeInvite":
            if let idNumber = data["id"] as? NSNumber {
                onRevokeInvite?(idNumber.intValue)
            } else if let idInt = data["id"] as? Int {
                onRevokeInvite?(idInt)
            }

        case "removePerson":
            if let id = data["id"] as? String, !id.isEmpty {
                onRemovePerson?(id)
            }

        case "copyText":
            if let text = data["text"] as? String {
                onCopyText?(text)
            }

        case "openBilling":
            onOpenBilling?()

        case "disconnectFromServer":
            onDisconnectFromServer?()

        case "closePeople":
            onClosePeople?()

        default:
            break
        }
    }

    // MARK: - Push events to JavaScript

    /// Push an event to the people page by calling
    /// `window.freeflowbridge.onEvent(data)`.
    ///
    /// - Parameters:
    ///   - name: The event name (e.g. "peopleState").
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
                Log.debug("[PeopleBridge] pushEvent(\(name)) error: \(error)")
            }
        }
    }

    /// Push the current people state to the web page.
    ///
    /// - Parameters:
    ///   - hasCreditCard: Whether the user has a credit card on file.
    ///   - invites: Array of invite dictionaries.
    ///   - people: Array of people dictionaries.
    func pushPeopleState(
        hasCreditCard: Bool,
        invites: [[String: Any]],
        people: [[String: Any]],
        connectedServer: String? = nil,
        isAdmin: Bool = false,
        canDisconnect: Bool = false
    ) {
        pushEvent(
            name: "peopleState",
            data: [
                "hasCreditCard": hasCreditCard,
                "invites": invites,
                "people": people,
                "connectedServer": connectedServer ?? "",
                "isAdmin": isAdmin,
                "canDisconnect": canDisconnect,
            ]
        )
    }

    /// Push an invite created confirmation event.
    ///
    /// - Parameter invite: Dictionary describing the newly created invite.
    func pushInviteCreated(invite: [String: Any]) {
        pushEvent(name: "inviteCreated", data: ["invite": invite])
    }

    /// Push an invite revoked confirmation event.
    ///
    /// - Parameter id: The id of the revoked invite.
    func pushInviteRevoked(id: Int) {
        pushEvent(name: "inviteRevoked", data: ["id": id])
    }

    /// Push a person removed confirmation event.
    ///
    /// - Parameter id: The id of the removed person.
    func pushPersonRemoved(id: String) {
        pushEvent(name: "personRemoved", data: ["id": id])
    }

    /// Push a disconnected-from-server confirmation event.
    func pushDisconnectedFromServer() {
        pushEvent(name: "disconnectedFromServer")
    }

    /// Push an action error event to the people page.
    ///
    /// - Parameter message: A human-readable error message.
    func pushActionError(message: String) {
        pushEvent(name: "actionError", data: ["message": message])
    }

    /// Push a page error event to the people page.
    ///
    /// - Parameter message: A human-readable error message.
    func pushPageError(message: String) {
        pushEvent(name: "pageError", data: ["message": message])
    }

    /// Push a toast notification event to the people page.
    ///
    /// - Parameter message: The toast message to display.
    func pushToast(message: String) {
        pushEvent(name: "toast", data: ["message": message])
    }
}
