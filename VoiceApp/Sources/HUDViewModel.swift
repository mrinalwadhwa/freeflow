import AppKit
import Combine
import Foundation
import SwiftUI
import VoiceKit

/// Smoothing factor for audio level metering. Higher values = more responsive,
/// lower values = smoother. Range 0.0 (frozen) to 1.0 (no smoothing).
private let audioLevelSmoothing: Float = 0.6

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

    /// Current audio input level (0.0 to 1.0) for driving the waveform bars.
    /// Smoothed to avoid jittery animation. Reset to 0 when not recording.
    @Published private(set) var audioLevel: Float = 0

    /// The active microphone name to show in the callout, or nil when hidden.
    @Published private(set) var micCalloutName: String?

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

    /// Whether the mic callout should show on the next recording transition.
    /// Set to true after a mic switch via the menu, reset after showing.
    private(set) var showMicCalloutOnNextRecording: Bool = false

    // MARK: - Pipeline references

    private var pipelineState: RecordingState = .idle

    // MARK: - Audio level

    /// The audio provider whose `audioLevelStream` we observe while recording.
    private var audioProvider: AudioProviding?
    private var audioLevelTask: Task<Void, Never>?

    // MARK: - Timers

    /// Duration before the slow-processing message appears.
    private let slowProcessingThreshold: TimeInterval

    /// Duration the mic callout stays visible before auto-dismissing.
    private let micCalloutDuration: TimeInterval

    private var slowProcessingTask: Task<Void, Never>?
    private var slowProcessingFired = false

    private var hoverGraceTask: Task<Void, Never>?
    private var micCalloutTask: Task<Void, Never>?

    // MARK: - Observation

    private var observationTask: Task<Void, Never>?

    /// Set the audio provider so we can observe its level stream during recording.
    func setAudioProvider(_ provider: AudioProviding?) {
        self.audioProvider = provider
    }

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default,
        slowProcessingThreshold: TimeInterval = 7.0,
        micCalloutDuration: TimeInterval = 3.0
    ) {
        self.shortcuts = shortcuts
        self.slowProcessingThreshold = slowProcessingThreshold
        self.micCalloutDuration = micCalloutDuration
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
        micCalloutTask?.cancel()
        micCalloutTask = nil
        stopAudioLevelObservation()
        pipelineState = .idle
        slowProcessingFired = false
        micCalloutName = nil
        visualState = .minimized
    }

    // MARK: - UI-local inputs

    /// Called when the mouse enters the HUD area.
    /// A short delay prevents the tooltip from flashing on casual mouse movement.
    func mouseEntered() {
        hoverGraceTask?.cancel()
        hoverGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s
            guard !Task.isCancelled else { return }
            self?.isHovering = true
            self?.recalculate()
        }
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
        let t = CFAbsoluteTimeGetCurrent()
        Log.debug("[HUD] State changed: \(previous) → \(state) at \(t)")

        // Cancel slow-processing timer when leaving processing.
        if state != .processing {
            slowProcessingTask?.cancel()
            slowProcessingTask = nil
            slowProcessingFired = false
        }

        switch state {
        case .idle:
            // Successful injection or cancellation — collapse to minimized.
            stopAudioLevelObservation()
            visualState = .minimized

        case .recording:
            if previous == .idle {
                // Show mic callout on first recording or after a mic switch.
                if isFirstRecording || showMicCalloutOnNextRecording {
                    showMicCallout()
                }
                startAudioLevelObservation()
            }
            recalculate()
            Log.debug("[HUD] Visual state now: \(visualState)")

        case .processing:
            stopAudioLevelObservation()
            startSlowProcessingTimer()
            recalculate()

        case .injecting:
            // Injection is committed — the text will appear momentarily.
            // Collapse the pill now rather than waiting for the clipboard
            // restore delay (~200ms) and the idle transition. This makes
            // the pill disappear in sync with the text appearing instead
            // of lingering in the processing state.
            stopAudioLevelObservation()
            visualState = .minimized

        case .injectionFailed:
            recalculate()

        case .sessionExpired:
            stopAudioLevelObservation()
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

        case .sessionExpired:
            return .sessionExpired
        }
    }

    // MARK: - Mic callout

    /// The name of the active microphone. Set by the controller when a
    /// device provider is available.
    var activeMicName: String?

    /// Mark that the user switched microphones, so the callout shows on the
    /// next recording.
    func requestMicCallout() {
        showMicCalloutOnNextRecording = true
    }

    /// Show the mic callout tooltip and schedule auto-dismiss.
    private func showMicCallout() {
        guard let name = activeMicName, !name.isEmpty else { return }

        isFirstRecording = false
        showMicCalloutOnNextRecording = false
        micCalloutName = name

        micCalloutTask?.cancel()
        micCalloutTask = Task { [weak self, micCalloutDuration] in
            try? await Task.sleep(
                nanoseconds: UInt64(micCalloutDuration * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.micCalloutName = nil
        }
    }

    /// Dismiss the mic callout immediately (e.g. when the user taps it).
    func dismissMicCallout() {
        micCalloutTask?.cancel()
        micCalloutTask = nil
        micCalloutName = nil
    }

    // MARK: - Audio level observation

    private func startAudioLevelObservation() {
        audioLevelTask?.cancel()
        audioLevel = 0
        let provider = audioProvider
        audioLevelTask = Task { [weak self] in
            // The audio level stream is created inside
            // audioProvider.startRecording(), which runs in a detached
            // task after the coordinator emits .recording. Poll briefly
            // so we pick it up once it exists.
            var stream: AsyncStream<Float>?
            for _ in 0..<20 {  // up to ~200ms
                stream = provider?.audioLevelStream
                if stream != nil { break }
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
                guard !Task.isCancelled else { return }
            }
            guard let stream else { return }

            for await level in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                // Exponential smoothing to avoid jitter.
                let smoothed =
                    audioLevelSmoothing * level
                    + (1.0 - audioLevelSmoothing) * self.audioLevel
                self.audioLevel = smoothed
            }
        }
    }

    private func stopAudioLevelObservation() {
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevel = 0
    }

    deinit {
        observationTask?.cancel()
        slowProcessingTask?.cancel()
        hoverGraceTask?.cancel()
        micCalloutTask?.cancel()
        audioLevelTask?.cancel()
    }
}
