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
    private var transcriptBuffer: TranscriptBuffer?
    private var textInjector: (any TextInjecting)?

    private var visualStateObservation: Task<Void, Never>?
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var globalClickMonitor: Any?
    private var localPasteMonitor: Any?
    private var globalPasteMonitor: Any?

    // MARK: - Init

    init(
        shortcuts: ShortcutConfiguration = .default
    ) {
        self.viewModel = HUDViewModel(
            shortcuts: shortcuts
        )
        setupViewModelActions()
    }

    // MARK: - Lifecycle

    /// Begin observing the coordinator and pipeline to drive the HUD.
    func start(
        coordinator: RecordingCoordinator,
        pipeline: DictationPipeline? = nil,
        audioDeviceProvider: (any AudioDeviceProviding)? = nil,
        audioProvider: (any AudioProviding)? = nil,
        transcriptBuffer: TranscriptBuffer? = nil,
        textInjector: (any TextInjecting)? = nil
    ) {
        self.coordinator = coordinator
        self.pipeline = pipeline
        self.audioDeviceProvider = audioDeviceProvider
        self.transcriptBuffer = transcriptBuffer
        self.textInjector = textInjector

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
        installPasteShortcutMonitors()

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
        removePasteShortcutMonitors()
        viewModel.stop()
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - Activation helpers

    /// Call when push-to-talk recording begins (hotkey held).
    func hotkeyHeld() {
        viewModel.hotkeyHeld()
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
    /// HUD pill. Needed because the window has `ignoresMouseEvents = true`
    /// in minimized, ready, and noTarget states so clicks pass through
    /// to apps behind.
    private func installClickMonitor() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self else { return }
            let state = self.viewModel.visualState
            let mouseLocation = NSEvent.mouseLocation
            guard self.hudWindow?.isMouseOverVisibleContent(mouseLocation) == true else { return }

            switch state {
            case .minimized, .ready:
                self.startHandsFreeFromClick()
            case .noTarget:
                self.dismissNoTarget()
            default:
                break
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    // MARK: - Paste shortcut (⌃⌥V) handling

    /// Virtual key code for 'V'.
    private static let vKeyCode: UInt16 = 9

    /// Install local and global key event monitors to handle ⌃⌥V.
    ///
    /// When the HUD is in the no-target state, ⌃⌥V lets the user select a
    /// text field and paste the buffered transcript without re-dictating.
    /// The shortcut also works when no-target is not showing, as a general
    /// "paste last transcript" action.
    private func installPasteShortcutMonitors() {
        localPasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isPasteShortcut(event) == true {
                self?.handlePasteShortcut()
                return nil  // Consume the event.
            }
            return event
        }

        globalPasteMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if self?.isPasteShortcut(event) == true {
                self?.handlePasteShortcut()
            }
        }
    }

    private func removePasteShortcutMonitors() {
        if let monitor = localPasteMonitor {
            NSEvent.removeMonitor(monitor)
            localPasteMonitor = nil
        }
        if let monitor = globalPasteMonitor {
            NSEvent.removeMonitor(monitor)
            globalPasteMonitor = nil
        }
    }

    /// Check whether a key event is the ⌃⌥V paste shortcut.
    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.vKeyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags == [.control, .option]
    }

    /// Paste the buffered transcript into the currently focused text field.
    private func handlePasteShortcut() {
        guard let transcriptBuffer, let textInjector else { return }

        // Dismiss the no-target hint if it is showing.
        if viewModel.visualState == .noTarget {
            viewModel.dismissNoTarget()
            guard let coordinator else { return }
            Task {
                await coordinator.reset()
            }
        }

        Task {
            guard let transcript = await transcriptBuffer.consume() else {
                Log.debug("[HUD] ⌃⌥V pressed but no transcript in buffer")
                return
            }

            // Read fresh context at the moment of paste.
            let context = await AXAppContextProvider().readContext()

            do {
                try await textInjector.inject(text: transcript, into: context)
                Log.debug("[HUD] ⌃⌥V pasted transcript (\(transcript.count) chars)")
            } catch {
                Log.debug("[HUD] ⌃⌥V paste failed: \(error)")
                // Re-store so the user can try again.
                await transcriptBuffer.store(transcript)
            }
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
        case .sessionExpired:
            dismissNoTarget()
            return true
        case .minimized, .ready, .listeningHeld, .processingCollapsing:
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
        if let monitor = localPasteMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalPasteMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
