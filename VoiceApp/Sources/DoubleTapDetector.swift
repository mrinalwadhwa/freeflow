import Foundation
import VoiceKit

/// Distinguish a double-tap gesture from a press-and-hold gesture on the
/// same physical key.
///
/// The hotkey provider emits raw `.pressed` / `.released` events. This
/// detector applies a timing window to classify the gesture:
///
/// - **Hold**: key pressed and held beyond the timing window → push-to-talk.
/// - **Double-tap**: two quick press–release cycles within the timing window
///   → hands-free toggle.
///
/// Usage: feed every `HotkeyEvent` into `handleEvent(_:)`. The detector
/// calls back with a `DoubleTapGesture` once the gesture is resolved.
@MainActor
final class DoubleTapDetector {

    /// The resolved gesture after analyzing press/release timing.
    enum Gesture {
        /// The key was held down past the timing window (push-to-talk).
        case hold

        /// Two quick taps detected within the timing window (hands-free toggle).
        case doubleTap
    }

    /// Called when a gesture is resolved. Always called on the main actor.
    var onGesture: ((Gesture) -> Void)?

    /// Called when the held key is released. Only fires after a `.hold` gesture.
    var onHoldRelease: (() -> Void)?

    /// The maximum interval between two taps to count as a double-tap.
    private let doubleTapInterval: TimeInterval

    // MARK: - Internal state

    /// Timestamp of the most recent key-down event.
    private var lastPressTime: Date?

    /// Timestamp of the most recent key-up event.
    private var lastReleaseTime: Date?

    /// Number of complete tap cycles (press + release) in the current sequence.
    private var tapCount: Int = 0

    /// Whether the current press has been resolved as a hold.
    private var holdResolved: Bool = false

    /// Whether the current press has been resolved as a double-tap.
    private var doubleTapResolved: Bool = false

    /// Timer that fires when the timing window expires after a press,
    /// resolving the gesture as a hold.
    private var holdTimer: Task<Void, Never>?

    /// Timer that fires when the timing window expires after a single tap,
    /// resolving the gesture as a hold (the first tap was just a short press).
    private var tapWindowTimer: Task<Void, Never>?

    // MARK: - Init

    /// Create a detector with the given double-tap timing window.
    ///
    /// - Parameter doubleTapInterval: Maximum seconds between the first press
    ///   and the second press to count as a double-tap. Default is 0.35s.
    init(doubleTapInterval: TimeInterval = 0.35) {
        self.doubleTapInterval = doubleTapInterval
    }

    // MARK: - Event handling

    /// Feed a hotkey event into the detector.
    ///
    /// Call this for every `.pressed` and `.released` event from the hotkey
    /// provider. The detector will call `onGesture` once it resolves the
    /// gesture type.
    func handleEvent(_ event: HotkeyEvent) {
        switch event {
        case .pressed:
            handlePress()
        case .released:
            handleRelease()
        }
    }

    /// Reset all internal state. Call when the pipeline is cancelled or
    /// the app needs to abandon gesture detection.
    func reset() {
        cancelTimers()
        lastPressTime = nil
        lastReleaseTime = nil
        tapCount = 0
        holdResolved = false
        doubleTapResolved = false
    }

    // MARK: - Press handling

    private func handlePress() {
        let now = Date()

        if tapCount == 1, let lastRelease = lastReleaseTime {
            // Second press. Check if it's within the double-tap window
            // measured from the first press.
            let intervalSinceRelease = now.timeIntervalSince(lastRelease)
            if let firstPress = lastPressTime {
                let intervalSinceFirstPress = now.timeIntervalSince(firstPress)
                if intervalSinceFirstPress <= doubleTapInterval
                    && intervalSinceRelease <= doubleTapInterval
                {
                    // Double-tap detected.
                    cancelTimers()
                    doubleTapResolved = true
                    holdResolved = false
                    tapCount = 2
                    lastPressTime = now
                    onGesture?(.doubleTap)
                    return
                }
            }
        }

        // First press (or a press after the window expired — treated as fresh).
        cancelTimers()
        lastPressTime = now
        lastReleaseTime = nil
        tapCount = 0
        holdResolved = false
        doubleTapResolved = false

        // Start a timer: if the key is still held when this fires, it's a hold.
        holdTimer = Task { [weak self, doubleTapInterval] in
            try? await Task.sleep(nanoseconds: UInt64(doubleTapInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resolveAsHold()
        }
    }

    // MARK: - Release handling

    private func handleRelease() {
        let now = Date()

        if doubleTapResolved {
            // Release after double-tap. The gesture was already delivered.
            // Reset so the next press starts fresh.
            reset()
            return
        }

        if holdResolved {
            // Release after a hold — notify that the hold ended.
            onHoldRelease?()
            reset()
            return
        }

        // Release before the hold timer fired — this is a quick tap.
        cancelTimers()
        lastReleaseTime = now
        tapCount += 1

        if tapCount == 1 {
            // First tap completed. Wait for a possible second press.
            let remaining: TimeInterval
            if let pressTime = lastPressTime {
                let elapsed = now.timeIntervalSince(pressTime)
                remaining = max(0, doubleTapInterval - elapsed)
            } else {
                remaining = doubleTapInterval
            }

            tapWindowTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Timing window expired with only one tap. This was a single
                // short press — not a hold, not a double-tap. We treat this
                // as a tap-and-release with no pipeline action (the key was
                // released too quickly to be a hold, and no second tap came).
                self?.reset()
            }
        }
    }

    // MARK: - Resolution

    private func resolveAsHold() {
        guard !holdResolved, !doubleTapResolved else { return }
        holdResolved = true
        tapCount = 0
        cancelTimers()
        onGesture?(.hold)
    }

    // MARK: - Timer management

    private func cancelTimers() {
        holdTimer?.cancel()
        holdTimer = nil
        tapWindowTimer?.cancel()
        tapWindowTimer = nil
    }

    deinit {
        holdTimer?.cancel()
        tapWindowTimer?.cancel()
    }
}
