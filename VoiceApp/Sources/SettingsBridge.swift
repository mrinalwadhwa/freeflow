import Foundation
import VoiceKit
import WebKit

/// Handle messages from the settings web page running in WKWebView.
///
/// JavaScript calls `window.webkit.messageHandlers.voice.postMessage(data)`
/// where `data` is a JSON object with an `action` field. The bridge
/// dispatches each action to the registered handler closure.
///
/// To push events back to JavaScript, call `pushEvent(name:data:)` which
/// evaluates `window.voicebridge.onEvent(...)` in the web view.
///
/// Actions received from settings page:
///   - getSettings: { action }
///   - setSoundFeedback: { action, data: { enabled } }
///   - setShortcut: { action, data: { shortcut, label, type, ... } }
///   - setLanguage: { action, data: { code } }
///   - listMicrophones: { action }
///   - selectMicrophone: { action, data: { id } }
///   - startMicPreview: { action }
///   - stopMicPreview: { action }
///   - closeSettings: { action }
///
/// Events pushed to settings page:
///   - settingsState: { event, soundFeedback, shortcuts, language, languages }
///   - microphoneList: { event, devices: [...], currentId }
///   - microphoneSelected: { event, id }
///   - audioLevel: { event, level }
@MainActor
final class SettingsBridge: NSObject, WKScriptMessageHandler {

    /// The web view to push events back to. Set by SettingsController
    /// after the window is created.
    weak var webView: WKWebView?

    /// Handler closures for each bridge action. Set by SettingsController
    /// to wire native services to settings page requests.
    var onGetSettings: (() -> Void)?
    var onSetSoundFeedback: ((_ enabled: Bool) -> Void)?
    var onSetShortcut: ((_ shortcut: String, _ data: [String: Any]) -> Void)?
    var onSetLanguage: ((_ code: String) -> Void)?
    var onListMicrophones: (() -> Void)?
    var onSelectMicrophone: ((_ id: UInt32) -> Void)?
    var onStartMicPreview: (() -> Void)?
    var onStopMicPreview: (() -> Void)?
    var onCloseSettings: (() -> Void)?

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
        //   bridge.send("setSoundFeedback", { enabled: true })
        // becomes { action: "setSoundFeedback", data: { enabled: true } }.
        let data = body["data"] as? [String: Any] ?? [:]

        switch action {
        case "getSettings":
            onGetSettings?()

        case "setSoundFeedback":
            if let enabled = data["enabled"] as? Bool {
                onSetSoundFeedback?(enabled)
            }

        case "setShortcut":
            if let shortcut = data["shortcut"] as? String {
                onSetShortcut?(shortcut, data)
            }

        case "setLanguage":
            if let code = data["code"] as? String {
                onSetLanguage?(code)
            }

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

        case "closeSettings":
            onCloseSettings?()

        default:
            break
        }
    }

    // MARK: - Push events to JavaScript

    /// Push an event to the settings page by calling
    /// `window.voicebridge.onEvent(data)`.
    ///
    /// - Parameters:
    ///   - name: The event name (e.g. "settingsState").
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

        let script = "window.voicebridge && window.voicebridge.onEvent(\(jsonString));"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                Log.debug("[SettingsBridge] pushEvent(\(name)) error: \(error)")
            }
        }
    }

    /// Push the current settings state to the web page.
    ///
    /// - Parameters:
    ///   - soundFeedback: Whether sound feedback is enabled.
    ///   - shortcuts: Dictionary of shortcut labels keyed by shortcut name
    ///     (e.g. `["dictate": "Right Option ⌥", "handsfree": "⌥⌥",
    ///     "paste": "⌃⌥V", "cancel": "Escape"]`).
    ///   - language: The ISO-639-1 code of the current language (e.g. "en").
    ///   - languages: Array of dictionaries with "code" and "name" keys
    ///     for all supported languages.
    func pushSettingsState(
        soundFeedback: Bool,
        shortcuts: [String: String],
        language: String,
        languages: [[String: String]]
    ) {
        pushEvent(
            name: "settingsState",
            data: [
                "soundFeedback": soundFeedback,
                "shortcuts": shortcuts,
                "language": language,
                "languages": languages,
            ]
        )
    }

    /// Push the available microphone list to the settings page.
    func pushMicrophoneList(devices: [[String: Any]], currentId: UInt32?) {
        var data: [String: Any] = ["devices": devices]
        if let currentId {
            data["currentId"] = currentId
        }
        pushEvent(name: "microphoneList", data: data)
    }

    /// Push a microphone selection confirmation event.
    func pushMicrophoneSelected(id: UInt32) {
        pushEvent(name: "microphoneSelected", data: ["id": id])
    }

    /// Push an audio level event with the current RMS level.
    func pushAudioLevel(level: Float) {
        pushEvent(name: "audioLevel", data: ["level": level])
    }
}
