import AppKit
import Carbon.HIToolbox
import Foundation
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
    private var audioDeviceProvider: (any AudioDeviceProviding)?

    private var visualStateObservation: Task<Void, Never>?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var globalClickMonitor: Any?

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default,
        slowProcessingThreshold: TimeInterval = 5.0
    ) {
        self.viewModel = HUDViewModel(
            shortcuts: shortcuts,
            slowProcessingThreshold: slowProcessingThreshold
        )
        setupViewModelActions()
    }

    // MARK: - Lifecycle

    /// Begin observing the coordinator and pipeline to drive the HUD.
    func start(
        coordinator: RecordingCoordinator,
        pipeline: DictationPipeline? = nil,
        audioDeviceProvider: (any AudioDeviceProviding)? = nil,
        audioProvider: (any AudioProviding)? = nil
    ) {
        self.coordinator = coordinator
        self.pipeline = pipeline
        self.audioDeviceProvider = audioDeviceProvider

        // Wire audio provider for live level metering.
        viewModel.setAudioProvider(audioProvider)

        // Seed the view model with the current mic name.
        if let provider = audioDeviceProvider {
            Task {
                let device = await provider.currentDevice()
                self.viewModel.activeMicName = device?.name
            }
        }

        viewModel.observe(coordinator: coordinator)
        ensureWindow()

        installEscapeMonitors()
        installClickMonitor()

        // Watch visual state changes, mouse screen, and hover to animate
        // the window. Hover detection is done here via global mouse
        // position polling because NSTrackingArea is unreliable on
        // transparent non-activating panels with large invisible regions.
        visualStateObservation?.cancel()
        visualStateObservation = Task { [weak self] in
            var previousState: HUDVisualState?
            var previousScreenFrame: NSRect?
            var wasHovering = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)  // ~60fps
                guard !Task.isCancelled else { break }
                guard let self else { break }

                let mouseLocation = NSEvent.mouseLocation

                // Detect if the mouse moved to a different screen.
                let currentScreen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
                let currentScreenFrame = currentScreen?.frame
                let screenChanged = currentScreenFrame != previousScreenFrame
                if screenChanged {
                    previousScreenFrame = currentScreenFrame
                }

                // Hover detection: check if the mouse is over the visible
                // content region (capsule when minimized, full pill when
                // expanded). This replaces NSTrackingArea.
                let isOverContent =
                    self.hudWindow?.isMouseOverVisibleContent(mouseLocation) ?? false
                if isOverContent && !wasHovering {
                    wasHovering = true
                    self.viewModel.mouseEntered()
                } else if !isOverContent && wasHovering {
                    wasHovering = false
                    self.viewModel.mouseExited()
                }

                let current = self.viewModel.visualState
                if screenChanged {
                    self.hudWindow?.repositionToCurrentScreen()
                }
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
        removeClickMonitor()
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

    /// Notify the view model that the user switched microphones and refresh
    /// the active mic name. Called from the menu bar after `selectDevice`.
    func microphoneSwitched() {
        viewModel.requestMicCallout()
        if let provider = audioDeviceProvider {
            Task {
                let device = await provider.currentDevice()
                self.viewModel.activeMicName = device?.name
            }
        }
    }

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

    // MARK: - Click-to-record monitor

    /// Install a global mouse click monitor that detects clicks on the
    /// minimized/ready capsule. Needed because the window has
    /// `ignoresMouseEvents = true` in these states so clicks pass through.
    private func installClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self else { return }
            let state = self.viewModel.visualState
            guard state == .minimized || state == .ready else { return }
            let mouseLocation = NSEvent.mouseLocation
            if self.hudWindow?.isMouseOverVisibleContent(mouseLocation) == true {
                self.startHandsFreeFromClick()
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
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
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
