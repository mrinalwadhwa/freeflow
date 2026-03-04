import Foundation

/// Provides global hotkey registration and event delivery.
///
/// The hotkey listener runs system-wide, capturing key events from any application.
/// Requires the app to be trusted for accessibility (AXIsProcessTrusted).
public protocol HotkeyProviding: Sendable {

    /// Register a global hotkey listener.
    ///
    /// The callback fires on the main thread for each press and release event.
    /// Only one listener can be active at a time; calling `register` again
    /// replaces the previous callback.
    ///
    /// - Parameter callback: Called with `.pressed` on key-down and `.released` on key-up.
    /// - Throws: If the event tap cannot be created (e.g. accessibility permission not granted).
    func register(callback: @escaping @Sendable (HotkeyEvent) -> Void) throws

    /// Remove the global hotkey listener and release the event tap.
    func unregister()
}
