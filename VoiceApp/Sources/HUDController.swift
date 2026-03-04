import AppKit
import Carbon.HIToolbox
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
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?

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

        installEscapeMonitors()

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
        removeEscapeMonitors()
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

    // MARK: - Escape key handling

    /// Install local and global key event monitors to handle Escape.
    ///
    /// A local monitor catches Escape when the app is frontmost. A global
    /// monitor catches Escape when another app is frontmost (the typical
    /// case — the user is dictating into another app). Both route to
    /// `handleEscape()` which checks the current visual state.
    private func installEscapeMonitors() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                if self?.handleEscape() == true {
                    return nil  // Consume the event.
                }
            }
            return event
        }

        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.handleEscape()
            }
        }
    }

    private func removeEscapeMonitors() {
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            localEscapeMonitor = nil
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
            globalEscapeMonitor = nil
        }
    }

    /// Route Escape to the appropriate action based on the current visual state.
    ///
    /// - Returns: `true` if Escape was handled (the event should be consumed).
    @discardableResult
    private func handleEscape() -> Bool {
        switch viewModel.visualState {
        case .listeningHandsFree:
            cancelPipeline()
            return true
        case .processingSlow:
            cancelPipeline()
            return true
        case .noTarget:
            dismissNoTarget()
            return true
        case .minimized, .ready, .listeningHeld, .processing:
            return false
        }
    }

    deinit {
        visualStateObservation?.cancel()
        if let monitor = localEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEscapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
