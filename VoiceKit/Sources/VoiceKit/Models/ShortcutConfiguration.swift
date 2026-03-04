import Foundation

/// Key bindings for hotkeys and shortcut hints displayed in the HUD and menu bar.
///
/// All UI components read from this struct to render shortcut hints dynamically.
/// Defaults are hardcoded but centralized here for easy change. A settings UI
/// to customize these comes in a future track.
public struct ShortcutConfiguration: Sendable, Equatable {

    /// Display name of the hold-to-record key (e.g. "⌥ Right Option").
    public let holdToRecordKeyName: String

    /// Display name of the hands-free toggle gesture (e.g. "Double-tap ⌥ Right Option").
    public let handsFreeToggleName: String

    /// Timing window in seconds to distinguish a double-tap from two separate presses.
    public let doubleTapInterval: TimeInterval

    /// Display name of the paste-last-transcript shortcut (e.g. "⌃⌥V").
    public let pasteShortcutName: String

    /// Display name of the dismiss key (e.g. "Escape").
    public let dismissKeyName: String

    public init(
        holdToRecordKeyName: String = "⌥ Right Option",
        handsFreeToggleName: String = "Double-tap ⌥ Right Option",
        doubleTapInterval: TimeInterval = 0.35,
        pasteShortcutName: String = "⌃⌥V",
        dismissKeyName: String = "Escape"
    ) {
        self.holdToRecordKeyName = holdToRecordKeyName
        self.handsFreeToggleName = handsFreeToggleName
        self.doubleTapInterval = doubleTapInterval
        self.pasteShortcutName = pasteShortcutName
        self.dismissKeyName = dismissKeyName
    }

    /// Default configuration with standard key bindings.
    public static let `default` = ShortcutConfiguration()

    /// The instructional hint shown in the Ready state when the user hovers the HUD.
    ///
    /// Example: "Hold **⌥ Right Option** to dictate"
    public var holdToRecordHint: String {
        "Hold \(holdToRecordKeyName) to dictate"
    }

    /// The instructional hint shown in the No Target state.
    ///
    /// Example: "Select a text field, then ⌃⌥V to paste"
    public var noTargetHint: String {
        "Select a text field, then \(pasteShortcutName) to paste"
    }
}
