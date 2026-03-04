import AppKit
import Combine
import SwiftUI
import VoiceKit

/// Derive `HUDVisualState` from pipeline state and UI-local signals.
///
/// The view model observes `RecordingCoordinator.stateStream` and combines it
/// with hover, activation mode, and slow-processing timer to produce the
/// current `HUDVisualState`. SwiftUI views observe the published properties.
///
/// Action closures (`onCancel`, `onStop`, `onDismiss`, `onClickToRecord`) are
/// set by the `HUDController` and invoked by SwiftUI button actions. This
/// keeps the view layer free of pipeline references.
@MainActor
final class HUDViewModel: ObservableObject {

    // MARK: - Published state

    @Published private(set) var visualState: HUDVisualState = .minimized
    @Published private(set) var isHovering: Bool = false

    // MARK: - Action closures (set by HUDController)

    /// Called when the user taps ✕ to cancel (listening hands-free or slow processing).
    var onCancel: (() -> Void)?

    /// Called when the user taps ■ to stop recording (listening hands-free).
    var onStop: (() -> Void)?

    /// Called when the user dismisses the no-target state (✕ or Escape).
    var onDismiss: (() -> Void)?

    /// Called when the user clicks the minimized/ready capsule to start hands-free.
    var onClickToRecord: (() -> Void)?

    // MARK: - Configuration

    let shortcuts: ShortcutConfiguration

    // MARK: - UI-local tracking

    /// Whether the current or most recent recording was initiated hands-free.
    private(set) var isHandsFree: Bool = false

    /// Whether this is the first recording since app launch (for mic callout).
    private(set) var isFirstRecording: Bool = true

    // MARK: - Pipeline references

    private var pipelineState: RecordingState = .idle

    // MARK: - Timers

    /// Duration before the slow-processing message appears.
    private let slowProcessingThreshold: TimeInterval

    private var slowProcessingTask: Task<Void, Never>?
    private var slowProcessingFired = false

    private var hoverGraceTask: Task<Void, Never>?

    // MARK: - Observation

    private var observationTask: Task<Void, Never>?

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default,
        slowProcessingThreshold: TimeInterval = 3.0
    ) {
        self.shortcuts = shortcuts
        self.slowProcessingThreshold = slowProcessingThreshold
    }

    // MARK: - Observation lifecycle

    /// Begin observing a coordinator's state stream to drive visual state.
    func observe(coordinator: RecordingCoordinator) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await state in await coordinator.stateStream {
                guard !Task.isCancelled else { break }
                self?.handlePipelineState(state)
            }
        }
    }

    /// Stop observing and reset to minimized.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        slowProcessingTask?.cancel()
        slowProcessingTask = nil
        hoverGraceTask?.cancel()
        hoverGraceTask = nil
        pipelineState = .idle
        slowProcessingFired = false
        visualState = .minimized
    }

    // MARK: - UI-local inputs

    /// Called when the mouse enters the HUD area.
    func mouseEntered() {
        hoverGraceTask?.cancel()
        hoverGraceTask = nil
        isHovering = true
        recalculate()
    }

    /// Called when the mouse exits the HUD area.
    func mouseExited() {
        hoverGraceTask?.cancel()
        // Short grace period so the HUD does not flicker on casual mouse movement.
        hoverGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2s
            guard !Task.isCancelled else { return }
            self?.isHovering = false
            self?.recalculate()
        }
    }

    /// Called when the user clicks the minimized HUD to start hands-free dictation.
    func clickedToStartHandsFree() {
        isHandsFree = true
    }

    /// Called when push-to-talk recording begins (hotkey held).
    func hotkeyHeld() {
        isHandsFree = false
    }

    /// Called when hands-free recording begins via the toggle shortcut.
    func toggledHandsFree() {
        isHandsFree = true
    }

    /// Called when the user dismisses the no-target state (✕ or Escape).
    func dismissNoTarget() {
        // The coordinator should transition to idle; this handles the UI side
        // in case the dismiss happens before the coordinator round-trip.
        if pipelineState == .injectionFailed {
            // The controller will call coordinator.reset() — we just
            // anticipate the visual change.
            visualState = .minimized
        }
    }

    // MARK: - Pipeline state handling

    private func handlePipelineState(_ state: RecordingState) {
        let previous = pipelineState
        pipelineState = state

        // Cancel slow-processing timer when leaving processing.
        if state != .processing {
            slowProcessingTask?.cancel()
            slowProcessingTask = nil
            slowProcessingFired = false
        }

        switch state {
        case .idle:
            // Successful injection or cancellation — collapse to minimized.
            visualState = .minimized

        case .recording:
            // Mark first-recording flag consumed after the first transition.
            // The flag stays true during this recording; cleared on the next idle.
            if previous == .idle {
                // isHandsFree was set by the caller before pipeline.activate().
            }
            recalculate()

        case .processing:
            startSlowProcessingTimer()
            recalculate()

        case .injecting:
            // Injection in progress — still show processing indicator.
            // On success the coordinator transitions to idle → minimized.
            recalculate()

        case .injectionFailed:
            recalculate()
        }
    }

    // MARK: - Slow processing timer

    private func startSlowProcessingTimer() {
        slowProcessingTask?.cancel()
        slowProcessingFired = false
        slowProcessingTask = Task { [weak self, slowProcessingThreshold] in
            try? await Task.sleep(
                nanoseconds: UInt64(slowProcessingThreshold * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.slowProcessingFired = true
            self?.recalculate()
        }
    }

    // MARK: - State derivation

    /// Recompute `visualState` from all inputs.
    private func recalculate() {
        visualState = deriveVisualState()
    }

    private func deriveVisualState() -> HUDVisualState {
        switch pipelineState {
        case .idle:
            if isHovering {
                return .ready
            }
            return .minimized

        case .recording:
            if isHandsFree {
                return .listeningHandsFree
            }
            return .listeningHeld

        case .processing, .injecting:
            if slowProcessingFired {
                return .processingSlow
            }
            return .processing

        case .injectionFailed:
            return .noTarget
        }
    }

    // MARK: - First recording tracking

    /// Mark that the first recording has been shown. Call after the mic
    /// callout is displayed.
    func markFirstRecordingShown() {
        isFirstRecording = false
    }

    deinit {
        observationTask?.cancel()
        slowProcessingTask?.cancel()
        hoverGraceTask?.cancel()
    }
}
