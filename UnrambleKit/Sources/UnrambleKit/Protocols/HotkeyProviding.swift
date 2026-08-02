import Foundation

/// Provides global hotkey registration and event delivery.
///
/// The hotkey listener runs system-wide and reports presses from any
/// application. Individual implementations define their permission needs.
public protocol HotkeyProviding: Sendable {

    /// Register a global hotkey listener.
    ///
    /// The callback fires on the provider's delivery thread for each press and
    /// release event. Callers must dispatch UI work to the main actor.
    /// Only one listener can be active at a time; calling `register` again
    /// replaces the previous callback.
    ///
    /// - Parameter callback: Called with `.pressed` on key-down and `.released` on key-up.
    /// - Throws: If the provider cannot register its global shortcut.
    func register(callback: @escaping @Sendable (HotkeyEvent) -> Void) throws

    /// Register with the physical event timestamp converted into AVAudio Mach
    /// host-time ticks. Implementations without a native event clock may use
    /// callback-entry host time.
    func registerTimestamped(
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws

    /// Remove the global hotkey listener and release its system resources.
    func unregister()
}

extension HotkeyProviding {
    public func registerTimestamped(
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws {
        try register { event in
            callback(event, AudioCaptureReleaseFence.currentHostTime())
        }
    }
}
