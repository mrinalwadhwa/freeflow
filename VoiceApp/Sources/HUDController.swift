import AppKit
import VoiceKit

/// Drive the HUD overlay window based on pipeline state and UI-local signals.
///
/// `HUDController` observes `RecordingCoordinator.stateStream` and combines it
/// with hover, activation mode, and slow-processing timer (via `HUDViewModel`)
/// to produce the current `HUDVisualState`. It owns the `HUDOverlayWindow`
/// lifecycle and wires cancel/complete buttons to the pipeline.
@MainActor
final class HUDController {

    private var hudWindow: HUDOverlayWindow?
    private let viewModel: HUDViewModel

    private weak var coordinator: RecordingCoordinator?
    private weak var pipeline: DictationPipeline?

    private var visualStateObservation: Task<Void, Never>?

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default,
        slowProcessingThreshold: TimeInterval = 3.0
    ) {
        self.viewModel = HUDViewModel(
            shortcuts: shortcuts,
            slowProcessingThreshold: slowProcessingThreshold
        )
        setupViewModelActions()
    }

    // MARK: - Lifecycle

    /// Begin observing the coordinator and pipeline to drive the HUD.
    func start(coordinator: RecordingCoordinator, pipeline: DictationPipeline? = nil) {
        self.coordinator = coordinator
        self.pipeline = pipeline

        viewModel.observe(coordinator: coordinator)
        ensureWindow()

        // Watch visual state changes to animate the window.
        visualStateObservation?.cancel()
        visualStateObservation = Task { [weak self] in
            var previousState: HUDVisualState?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)  // ~60fps
                guard !Task.isCancelled else { break }
                guard let self else { break }
                let current = self.viewModel.visualState
                if current != previousState {
                    previousState = current
                    self.hudWindow?.animateToCurrentState()
                }
            }
        }
    }

    /// Stop observing and remove the HUD from screen.
    func stop() {
        visualStateObservation?.cancel()
        visualStateObservation = nil
        viewModel.stop()
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - Activation helpers

    /// Call when push-to-talk recording begins (hotkey held).
    func hotkeyHeld() {
        viewModel.hotkeyHeld()
    }

    /// Call when hands-free recording begins via toggle shortcut.
    func toggledHandsFree() {
        viewModel.toggledHandsFree()
    }

    // MARK: - Pipeline actions

    /// Cancel the current pipeline operation. Called from ✕ buttons and Escape.
    func cancelPipeline() {
        guard let pipeline else { return }
        Task {
            await pipeline.cancel()
        }
    }

    /// Complete the current recording. Called from the ■ stop button.
    func completePipeline() {
        guard let pipeline else { return }
        Task {
            await pipeline.complete()
        }
    }

    /// Dismiss the no-target state and return to minimized.
    func dismissNoTarget() {
        viewModel.dismissNoTarget()
        guard let coordinator else { return }
        Task {
            await coordinator.reset()
        }
    }

    // MARK: - View model wiring

    private func setupViewModelActions() {
        viewModel.onCancel = { [weak self] in
            self?.cancelPipeline()
        }
        viewModel.onStop = { [weak self] in
            self?.completePipeline()
        }
        viewModel.onDismiss = { [weak self] in
            self?.dismissNoTarget()
        }
        viewModel.onClickToRecord = { [weak self] in
            self?.startHandsFreeFromClick()
        }
    }

    // MARK: - Window lifecycle

    private func ensureWindow() {
        guard hudWindow == nil else { return }
        hudWindow = HUDOverlayWindow(viewModel: viewModel)
    }

    /// Start hands-free dictation from a click on the minimized/ready HUD.
    private func startHandsFreeFromClick() {
        viewModel.clickedToStartHandsFree()
        guard let pipeline else { return }
        Task {
            await pipeline.activate()
        }
    }

    deinit {
        visualStateObservation?.cancel()
    }
}
