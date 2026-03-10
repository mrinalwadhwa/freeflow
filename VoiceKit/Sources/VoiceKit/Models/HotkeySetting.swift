import Foundation

/// Configuration for the global dictation hotkey.
///
/// Supports two modes:
/// - Modifier-only keys (e.g., Right Option, Right Command)
/// - Modifier + key combinations (e.g., Cmd+Shift+D)
///
/// Persisted in UserDefaults. The `CGEventTapHotkeyProvider` reads this
/// on registration to determine which key events to monitor.
public struct HotkeySetting: Codable, Sendable, Equatable {

    /// The type of hotkey: a modifier key alone or a modifier + key combo.
    public enum HotkeyType: String, Codable, Sendable {
        /// A modifier key by itself (e.g., Right Option).
        case modifierOnly
        /// A modifier + key combination (e.g., Cmd+Shift+D).
        case modifierPlusKey
    }

    /// Modifier keys that can be used alone as hotkeys.
    public enum ModifierKey: String, Codable, Sendable, CaseIterable {
        case rightOption
        case leftOption
        case rightCommand
        case leftCommand
        case rightControl
        case leftControl
        case rightShift
        case leftShift

        /// The CGEvent device-dependent flags mask for this modifier.
        public var deviceFlag: UInt64 {
            switch self {
            // Device-dependent flag masks from IOKit/IOLLEvent.h
            case .rightOption: return 0x0000_0040  // NX_DEVICERALTKEYMASK
            case .leftOption: return 0x0000_0020  // NX_DEVICELALTKEYMASK
            case .rightCommand: return 0x0000_0010  // NX_DEVICERCMDKEYMASK
            case .leftCommand: return 0x0000_0008  // NX_DEVICELCMDKEYMASK
            case .rightControl: return 0x0000_2000  // NX_DEVICERCTLKEYMASK
            case .leftControl: return 0x0000_0001  // NX_DEVICELCTLKEYMASK
            case .rightShift: return 0x0000_0004  // NX_DEVICERSHIFTKEYMASK
            case .leftShift: return 0x0000_0002  // NX_DEVICELSHIFTKEYMASK
            }
        }

        /// Human-readable display name for the modifier key.
        public var displayName: String {
            switch self {
            case .rightOption: return "Right Option ⌥"
            case .leftOption: return "Left Option ⌥"
            case .rightCommand: return "Right Command ⌘"
            case .leftCommand: return "Left Command ⌘"
            case .rightControl: return "Right Control ⌃"
            case .leftControl: return "Left Control ⌃"
            case .rightShift: return "Right Shift ⇧"
            case .leftShift: return "Left Shift ⇧"
            }
        }

        /// Short symbol representation for UI hints.
        public var symbol: String {
            switch self {
            case .rightOption, .leftOption: return "⌥"
            case .rightCommand, .leftCommand: return "⌘"
            case .rightControl, .leftControl: return "⌃"
            case .rightShift, .leftShift: return "⇧"
            }
        }
    }

    /// The hotkey type.
    public var type: HotkeyType

    /// For `.modifierOnly` type: which modifier key.
    public var modifierKey: ModifierKey?

    /// For `.modifierPlusKey` type: the modifier flags (device-independent).
    public var modifierFlags: UInt?

    /// For `.modifierPlusKey` type: the virtual key code.
    public var keyCode: UInt16?

    /// For `.modifierPlusKey` type: human-readable key name.
    public var keyName: String?

    // MARK: - Initializers

    /// Create a modifier-only hotkey.
    public init(modifierKey: ModifierKey) {
        self.type = .modifierOnly
        self.modifierKey = modifierKey
        self.modifierFlags = nil
        self.keyCode = nil
        self.keyName = nil
    }

    /// Create a modifier + key combination hotkey.
    public init(modifierFlags: UInt, keyCode: UInt16, keyName: String) {
        self.type = .modifierPlusKey
        self.modifierKey = nil
        self.modifierFlags = modifierFlags
        self.keyCode = keyCode
        self.keyName = keyName
    }

    // MARK: - Display

    // MARK: - Modifier flag constants (device-independent)

    /// Control key modifier flag (NSEvent.ModifierFlags.control.rawValue).
    private static let controlFlag: UInt = 0x0004_0000

    /// Option key modifier flag (NSEvent.ModifierFlags.option.rawValue).
    private static let optionFlag: UInt = 0x0008_0000

    /// Shift key modifier flag (NSEvent.ModifierFlags.shift.rawValue).
    private static let shiftFlag: UInt = 0x0002_0000

    /// Command key modifier flag (NSEvent.ModifierFlags.command.rawValue).
    private static let commandFlag: UInt = 0x0010_0000

    /// Human-readable display name for the hotkey.
    public var displayName: String {
        switch type {
        case .modifierOnly:
            return modifierKey?.displayName ?? "Unknown"
        case .modifierPlusKey:
            var parts: [String] = []
            if let flags = modifierFlags {
                if flags & Self.controlFlag != 0 {
                    parts.append("⌃")
                }
                if flags & Self.optionFlag != 0 {
                    parts.append("⌥")
                }
                if flags & Self.shiftFlag != 0 {
                    parts.append("⇧")
                }
                if flags & Self.commandFlag != 0 {
                    parts.append("⌘")
                }
            }
            if let name = keyName {
                parts.append(name)
            }
            return parts.joined()
        }
    }

    /// Short hint text for UI (e.g., "⌥ Right Option").
    public var hintText: String {
        switch type {
        case .modifierOnly:
            if let key = modifierKey {
                return
                    "\(key.symbol) \(key.displayName.replacingOccurrences(of: " \(key.symbol)", with: ""))"
            }
            return displayName
        case .modifierPlusKey:
            return displayName
        }
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "hotkeyConfiguration"

    /// The currently configured hotkey. Defaults to Right Option.
    public static var current: HotkeySetting {
        get {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                let setting = try? JSONDecoder().decode(HotkeySetting.self, from: data)
            else {
                return .default
            }
            return setting
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        }
    }

    /// The default hotkey: Right Option.
    public static let `default` = HotkeySetting(modifierKey: .rightOption)

    // MARK: - Common presets

    /// Preset: Right Option (default)
    public static let rightOption = HotkeySetting(modifierKey: .rightOption)

    /// Preset: Left Option
    public static let leftOption = HotkeySetting(modifierKey: .leftOption)

    /// Preset: Right Command
    public static let rightCommand = HotkeySetting(modifierKey: .rightCommand)

    /// Preset: Right Control
    public static let rightControl = HotkeySetting(modifierKey: .rightControl)
}
