import Foundation

/// Key bindings for hotkeys and shortcut hints displayed in the HUD and menu bar.
///
/// All UI components read from this struct to render shortcut hints dynamically.
/// The hold-to-record key name is read from `HotkeySetting.current` so it updates
/// automatically when the user changes their hotkey in Settings.
public struct ShortcutConfiguration: Sendable, Equatable {

    /// Display name of the paste-last-transcript shortcut (e.g. "⌃⌥V").
    public let pasteShortcutName: String

    /// Display name of the dismiss key (e.g. "Escape").
    public let dismissKeyName: String

    public init(
        pasteShortcutName: String = "⌃⌥V",
        dismissKeyName: String = "Escape"
    ) {
        self.pasteShortcutName = pasteShortcutName
        self.dismissKeyName = dismissKeyName
    }

    /// Default configuration with standard key bindings.
    public static let `default` = ShortcutConfiguration()

    /// Display name of the hold-to-record key, read dynamically from settings.
    ///
    /// This is a computed property so it always reflects the current hotkey
    /// configuration, even after the user changes it in Settings.
    public var holdToRecordKeyName: String {
        HotkeySetting.current.displayName
    }

    /// The instructional hint shown in the Ready state when the user hovers the HUD.
    ///
    /// Example: "Hold **Right Option ⌥** to dictate"
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
