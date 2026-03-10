import Foundation

/// Centralized app settings with UserDefaults persistence.
///
/// Settings provides a single point of access for all user-configurable
/// options. Each setting is persisted immediately on write and read
/// fresh from UserDefaults on access, ensuring consistency across the app.
///
/// Thread-safe: all operations go through UserDefaults which handles
/// synchronization internally.
public final class Settings: @unchecked Sendable {

    /// Shared singleton instance.
    public static let shared = Settings()

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key: String {
        case soundFeedbackEnabled = "soundFeedbackEnabled"
        case hotkeyConfiguration = "hotkeyConfiguration"
        case handsfreeShortcutLabel = "handsfreeShortcutLabel"
        case pasteShortcutLabel = "pasteShortcutLabel"
        case cancelShortcutLabel = "cancelShortcutLabel"
    }

    // MARK: - Init

    private init() {
        // Register default values for settings that need them.
        defaults.register(defaults: [
            Key.soundFeedbackEnabled.rawValue: true
        ])
    }

    // MARK: - Sound Feedback

    /// Whether sound feedback (start/stop cues) is enabled.
    /// Defaults to `true` on first launch.
    public var soundFeedbackEnabled: Bool {
        get {
            defaults.bool(forKey: Key.soundFeedbackEnabled.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.soundFeedbackEnabled.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.soundFeedbackEnabled.rawValue]
            )
        }
    }

    // MARK: - Hotkey

    /// The configured dictation hotkey.
    /// Defaults to Right Option.
    public var hotkeySetting: HotkeySetting {
        get {
            guard let data = defaults.data(forKey: Key.hotkeyConfiguration.rawValue),
                let setting = try? JSONDecoder().decode(HotkeySetting.self, from: data)
            else {
                return .default
            }
            return setting
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotkeyConfiguration.rawValue)
                NotificationCenter.default.post(
                    name: .settingsDidChange,
                    object: self,
                    userInfo: ["key": Key.hotkeyConfiguration.rawValue]
                )
            }
        }
    }

    // MARK: - Shortcut Labels

    /// Display label for the hands-free mode shortcut.
    /// Defaults to "⌘⇧H" (Command+Shift+H).
    public var handsfreeShortcutLabel: String {
        get {
            defaults.string(forKey: Key.handsfreeShortcutLabel.rawValue) ?? "⌘⇧H"
        }
        set {
            defaults.set(newValue, forKey: Key.handsfreeShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.handsfreeShortcutLabel.rawValue]
            )
        }
    }

    /// Display label for the paste-last-transcript shortcut.
    /// Defaults to "⌃⌥V" (Control+Option+V).
    public var pasteShortcutLabel: String {
        get {
            defaults.string(forKey: Key.pasteShortcutLabel.rawValue) ?? "⌃⌥V"
        }
        set {
            defaults.set(newValue, forKey: Key.pasteShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.pasteShortcutLabel.rawValue]
            )
        }
    }

    /// Display label for the cancel shortcut.
    /// Defaults to "Escape".
    public var cancelShortcutLabel: String {
        get {
            defaults.string(forKey: Key.cancelShortcutLabel.rawValue) ?? "Escape"
        }
        set {
            defaults.set(newValue, forKey: Key.cancelShortcutLabel.rawValue)
            NotificationCenter.default.post(
                name: .settingsDidChange,
                object: self,
                userInfo: ["key": Key.cancelShortcutLabel.rawValue]
            )
        }
    }

    // MARK: - Observation

    /// Add an observer for settings changes.
    ///
    /// - Parameters:
    ///   - observer: The object to register as observer.
    ///   - selector: The selector to call when settings change.
    public func addObserver(_ observer: Any, selector: Selector) {
        NotificationCenter.default.addObserver(
            observer,
            selector: selector,
            name: .settingsDidChange,
            object: self
        )
    }

    /// Remove a settings observer.
    public func removeObserver(_ observer: Any) {
        NotificationCenter.default.removeObserver(
            observer,
            name: .settingsDidChange,
            object: self
        )
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when any setting changes. The `userInfo` dictionary contains
    /// a "key" entry with the raw string key of the changed setting.
    public static let settingsDidChange = Notification.Name("SettingsDidChange")
}
