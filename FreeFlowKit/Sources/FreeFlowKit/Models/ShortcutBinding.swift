import Foundation

/// A persistent representation of a keyboard shortcut binding.
///
/// Stores the modifier flags and virtual key code needed to detect a
/// shortcut at runtime, alongside a human-readable label for display.
/// Codable so it can be serialized to UserDefaults via JSONEncoder.
///
/// Used by `Settings` to persist the actual key bindings for the
/// handsfree, paste, and cancel shortcuts. Without this, only the
/// display label was saved and the runtime detection remained
/// hard-coded.
public struct ShortcutBinding: Codable, Sendable, Equatable {

    /// Device-independent modifier flags (NSEvent.ModifierFlags raw values).
    ///
    /// Uses the same constants as `HotkeySetting`:
    /// - Control: `0x0004_0000`
    /// - Option:  `0x0008_0000`
    /// - Shift:   `0x0002_0000`
    /// - Command: `0x0010_0000`
    public var modifierFlags: UInt

    /// The virtual key code (macOS `CGKeyCode` / `event.keyCode`).
    /// For modifier-only shortcuts this is 0.
    public var keyCode: UInt16

    /// Human-readable display label (e.g. "⌃⌥V", "⌘⇧H", "Escape").
    public var label: String

    // MARK: - Modifier flag constants (same as HotkeySetting)

    /// Control key modifier flag (NSEvent.ModifierFlags.control.rawValue).
    public static let controlFlag: UInt = 0x0004_0000

    /// Option key modifier flag (NSEvent.ModifierFlags.option.rawValue).
    public static let optionFlag: UInt = 0x0008_0000

    /// Shift key modifier flag (NSEvent.ModifierFlags.shift.rawValue).
    public static let shiftFlag: UInt = 0x0002_0000

    /// Command key modifier flag (NSEvent.ModifierFlags.command.rawValue).
    public static let commandFlag: UInt = 0x0010_0000

    // MARK: - Initializers

    public init(modifierFlags: UInt, keyCode: UInt16, label: String) {
        self.modifierFlags = modifierFlags
        self.keyCode = keyCode
        self.label = label
    }

    // MARK: - Matching

    /// Check whether an NSEvent matches this shortcut binding.
    ///
    /// Compares the event's key code and device-independent modifier flags
    /// against the stored binding. Only the four standard modifier bits
    /// (Control, Option, Shift, Command) are compared; Caps Lock, Fn, and
    /// other flags are masked out.
    ///
    /// - Parameter keyCode: The virtual key code from the event.
    /// - Parameter modifierFlags: The raw value of the event's
    ///   device-independent modifier flags.
    /// - Returns: `true` if the event matches this binding.
    public func matches(keyCode eventKeyCode: UInt16, modifierFlags eventFlags: UInt) -> Bool {
        guard eventKeyCode == keyCode else { return false }
        let mask = Self.controlFlag | Self.optionFlag | Self.shiftFlag | Self.commandFlag
        return (eventFlags & mask) == (modifierFlags & mask)
    }

    // MARK: - Convenience query

    /// Whether this binding has the Control modifier.
    public var hasControl: Bool { modifierFlags & Self.controlFlag != 0 }

    /// Whether this binding has the Option modifier.
    public var hasOption: Bool { modifierFlags & Self.optionFlag != 0 }

    /// Whether this binding has the Shift modifier.
    public var hasShift: Bool { modifierFlags & Self.shiftFlag != 0 }

    /// Whether this binding has the Command modifier.
    public var hasCommand: Bool { modifierFlags & Self.commandFlag != 0 }

    // MARK: - Default bindings

    /// Default paste shortcut: ⌃⌥V (Control+Option+V, key code 9).
    public static let defaultPaste = ShortcutBinding(
        modifierFlags: controlFlag | optionFlag,
        keyCode: 9,
        label: "⌃⌥V"
    )

    /// Default hands-free shortcut: ⌘⇧H (Command+Shift+H, key code 4).
    public static let defaultHandsfree = ShortcutBinding(
        modifierFlags: commandFlag | shiftFlag,
        keyCode: 4,
        label: "⌘⇧H"
    )

    /// Default cancel shortcut: Escape (no modifiers, key code 53).
    public static let defaultCancel = ShortcutBinding(
        modifierFlags: 0,
        keyCode: 53,
        label: "Escape"
    )
}
