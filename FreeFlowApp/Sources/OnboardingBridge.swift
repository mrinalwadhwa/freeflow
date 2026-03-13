import Foundation
import FreeFlowKit
import WebKit

/// Handle messages from the zone's web pages running in WKWebView.
///
/// JavaScript calls `window.webkit.messageHandlers.freeflow.postMessage(data)`
/// where `data` is a JSON object with an `action` field. The bridge
/// dispatches each action to the registered handler closure.
///
/// To push events back to JavaScript, call `pushEvent(name:data:)` which
/// evaluates `window.freeflowbridge.onEvent(...)` in the web view.
///
/// Actions received from web pages:
///   - redeemInvite: { action, token }
///   - storeToken: { action, token }
///   - emailAdded: { action, email }
///   - checkAccessibility: { action }
///   - openAccessibilitySettings: { action }
///   - requestMicrophone: { action }
///   - listMicrophones: { action }
///   - selectMicrophone: { action, data: { id } }
///   - startMicPreview: { action }
///   - stopMicPreview: { action }
///   - registerHotkey: { action }
///   - completeOnboarding: { action }
///   - openProvisioning: { action }
///   - changeEmail: { action, data: { email, callbackURL } }
///   - verifyEmailOtp: { action, data: { email, otp } }
///   - sendSignInOtp: { action, data: { email, type } }
///   - signInWithOtp: { action, data: { email, otp } }
///   - dismiss: { action }
///   - signInComplete: { action }
///   - emailAddedComplete: { action }
///
/// Events pushed to web pages:
///   - inviteRedeemed: { event, userId, hasEmail }
///   - inviteRedeemFailed: { event, error }
///   - permissionStatus: { event, accessibility, microphone }
///   - microphoneList: { event, devices: [...], currentId }
///   - microphoneSelected: { event, id }
///   - audioLevel: { event, level }
///   - dictationResult: { event, text }
///   - tokenStored: { event }
///   - changeEmailResult: { event, error? }
///   - verifyEmailOtpResult: { event, error? }
///   - sendSignInOtpResult: { event, error? }
///   - signInWithOtpResult: { event, error? }
@MainActor
final class OnboardingBridge: NSObject, WKScriptMessageHandler {

    /// The web view to push events back to. Set by OnboardingController
    /// after the window is created.
    weak var webView: WKWebView?

    /// Handler closures for each bridge action. Set by OnboardingController
    /// to wire native services to web page requests.
    var onRedeemInvite: ((_ token: String) -> Void)?
    var onStoreToken: ((_ token: String) -> Void)?
    var onEmailAdded: ((_ email: String) -> Void)?
    var onCheckAccessibility: (() -> Void)?
    var onOpenAccessibilitySettings: (() -> Void)?
    var onRequestMicrophone: (() -> Void)?
    var onListMicrophones: (() -> Void)?
    var onSelectMicrophone: ((_ id: UInt32) -> Void)?
    var onStartMicPreview: (() -> Void)?
    var onStopMicPreview: (() -> Void)?
    var onRegisterHotkey: (() -> Void)?
    var onCompleteOnboarding: (() -> Void)?
    var onOpenProvisioning: (() -> Void)?

    // Account page actions (add-email and sign-in flows)
    var onChangeEmail: ((_ email: String, _ callbackURL: String) -> Void)?
    var onVerifyEmailOtp: ((_ email: String, _ otp: String) -> Void)?
    var onSendSignInOtp: ((_ email: String, _ type: String) -> Void)?
    var onSignInWithOtp: ((_ email: String, _ otp: String) -> Void)?
    var onDismiss: (() -> Void)?
    var onSignInComplete: (() -> Void)?
    var onEmailAddedComplete: (() -> Void)?

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
        //   bridge.send("redeemInvite", { token: "abc" })
        // becomes { action: "redeemInvite", data: { token: "abc" } }.
        let data = body["data"] as? [String: Any] ?? [:]

        switch action {
        case "redeemInvite":
            if let token = data["token"] as? String {
                onRedeemInvite?(token)
            }

        case "storeToken":
            if let token = data["token"] as? String {
                onStoreToken?(token)
            }

        case "emailAdded":
            if let email = data["email"] as? String {
                onEmailAdded?(email)
            }

        case "checkAccessibility":
            onCheckAccessibility?()

        case "openAccessibilitySettings":
            onOpenAccessibilitySettings?()

        case "requestMicrophone":
            onRequestMicrophone?()

        case "listMicrophones":
            onListMicrophones?()

        case "selectMicrophone":
            if let idNumber = data["id"] as? NSNumber {
                onSelectMicrophone?(idNumber.uint32Value)
            } else if let idInt = data["id"] as? Int {
                onSelectMicrophone?(UInt32(idInt))
            }

        case "startMicPreview":
            onStartMicPreview?()

        case "stopMicPreview":
            onStopMicPreview?()

        case "registerHotkey":
            onRegisterHotkey?()

        case "completeOnboarding":
            onCompleteOnboarding?()

        case "openProvisioning":
            onOpenProvisioning?()

        case "changeEmail":
            if let email = data["email"] as? String {
                let callbackURL = data["callbackURL"] as? String ?? ""
                onChangeEmail?(email, callbackURL)
            }

        case "verifyEmailOtp":
            if let email = data["email"] as? String,
                let otp = data["otp"] as? String
            {
                onVerifyEmailOtp?(email, otp)
            }

        case "sendSignInOtp":
            if let email = data["email"] as? String {
                let type = data["type"] as? String ?? "sign-in"
                onSendSignInOtp?(email, type)
            }

        case "signInWithOtp":
            if let email = data["email"] as? String,
                let otp = data["otp"] as? String
            {
                onSignInWithOtp?(email, otp)
            }

        case "dismiss":
            onDismiss?()

        case "signInComplete":
            onSignInComplete?()

        case "emailAddedComplete":
            onEmailAddedComplete?()

        default:
            break
        }
    }

    // MARK: - Push events to JavaScript

    /// Push an event to the web page by calling
    /// `window.freeflowbridge.onEvent(data)`.
    ///
    /// - Parameters:
    ///   - name: The event name (e.g. "inviteRedeemed").
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
                Log.debug("[OnboardingBridge] pushEvent(\(name)) error: \(error)")
            }
        }
    }

    /// Push an inviteRedeemed event.
    func pushInviteRedeemed(userId: String, hasEmail: Bool) {
        pushEvent(
            name: "inviteRedeemed",
            data: [
                "userId": userId,
                "hasEmail": hasEmail,
            ])
    }

    /// Push an inviteRedeemFailed event.
    func pushInviteRedeemFailed(error: String) {
        pushEvent(
            name: "inviteRedeemFailed",
            data: [
                "error": error
            ])
    }

    /// Push a permissionStatus event.
    func pushPermissionStatus(accessibility: String, microphone: String) {
        pushEvent(
            name: "permissionStatus",
            data: [
                "accessibility": accessibility,
                "microphone": microphone,
            ])
    }

    /// Push a microphoneList event with available devices.
    func pushMicrophoneList(devices: [[String: Any]], currentId: UInt32?) {
        var data: [String: Any] = ["devices": devices]
        if let currentId {
            data["currentId"] = currentId
        }
        pushEvent(name: "microphoneList", data: data)
    }

    /// Push a microphoneSelected confirmation event.
    func pushMicrophoneSelected(id: UInt32) {
        pushEvent(name: "microphoneSelected", data: ["id": id])
    }

    /// Push an audioLevel event with the current RMS level.
    func pushAudioLevel(level: Float) {
        pushEvent(name: "audioLevel", data: ["level": level])
    }

    /// Push a dictationResult event.
    func pushDictationResult(text: String) {
        pushEvent(
            name: "dictationResult",
            data: [
                "text": text
            ])
    }

    /// Push a tokenStored event.
    func pushTokenStored() {
        pushEvent(name: "tokenStored")
    }

    // MARK: - Account page events

    /// Push a changeEmailResult event (success or error).
    func pushChangeEmailResult(error: String? = nil) {
        if let error {
            pushEvent(name: "changeEmailResult", data: ["error": error])
        } else {
            pushEvent(name: "changeEmailResult")
        }
    }

    /// Push a verifyEmailOtpResult event (success or error).
    func pushVerifyEmailOtpResult(error: String? = nil) {
        if let error {
            pushEvent(name: "verifyEmailOtpResult", data: ["error": error])
        } else {
            pushEvent(name: "verifyEmailOtpResult")
        }
    }

    /// Push a sendSignInOtpResult event (success or error).
    func pushSendSignInOtpResult(error: String? = nil) {
        if let error {
            pushEvent(name: "sendSignInOtpResult", data: ["error": error])
        } else {
            pushEvent(name: "sendSignInOtpResult")
        }
    }

    /// Push a signInWithOtpResult event (success or error).
    func pushSignInWithOtpResult(error: String? = nil) {
        if let error {
            pushEvent(name: "signInWithOtpResult", data: ["error": error])
        } else {
            pushEvent(name: "signInWithOtpResult")
        }
    }
}
