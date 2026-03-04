import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

#if canImport(Cocoa)
    import Cocoa
#endif

/// Check and request accessibility permissions using the macOS Accessibility API.
///
/// Microphone permission methods delegate to AVFoundation (stubbed here since
/// the capture track owns audio). Accessibility checks use AXIsProcessTrusted.
public final class AccessibilityPermissionProvider: PermissionProviding, @unchecked Sendable {

    private let lock = NSLock()

    /// Cached accessibility state, refreshed on each check.
    private var _cachedAccessibilityState: PermissionState = .notDetermined

    public init() {}

    // MARK: - Microphone (stub — owned by capture track)

    public func checkMicrophone() -> PermissionState {
        // Microphone permission is owned by the capture track.
        // Return notDetermined so the capture track's real provider takes precedence.
        return .notDetermined
    }

    public func requestMicrophone() async -> PermissionState {
        return .notDetermined
    }

    // MARK: - Accessibility

    public func checkAccessibility() -> PermissionState {
        #if canImport(ApplicationServices)
            let trusted = AXIsProcessTrusted()
            let state: PermissionState = trusted ? .granted : .denied
            lock.withLock { _cachedAccessibilityState = state }
            return state
        #else
            return .denied
        #endif
    }

    public func openAccessibilitySettings() {
        #if canImport(Cocoa)
            // Open System Settings > Privacy & Security > Accessibility
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        #endif
    }

    /// Poll for accessibility permission changes.
    ///
    /// Call this periodically after directing the user to System Settings.
    /// Returns the current state after re-checking AXIsProcessTrusted.
    public func refreshAccessibility() -> PermissionState {
        return checkAccessibility()
    }

    /// Wait for accessibility permission to be granted, polling at the given interval.
    ///
    /// - Parameters:
    ///   - interval: Polling interval in seconds (default 1.0).
    ///   - timeout: Maximum time to wait in seconds (default 60.0).
    /// - Returns: The final permission state.
    public func waitForAccessibility(
        pollingInterval interval: TimeInterval = 1.0,
        timeout: TimeInterval = 60.0
    ) async -> PermissionState {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let state = checkAccessibility()
            if state == .granted {
                return .granted
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        return checkAccessibility()
    }
}
