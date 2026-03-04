import AppKit
import VoiceKit

/// Manage the HUD overlay window lifecycle based on recording state.
///
/// `HUDController` observes a `RecordingCoordinator`'s state stream and
/// shows or hides the floating HUD window as the state changes. It runs
/// all UI work on the main actor.
@MainActor
final class HUDController {

    private var hudWindow: HUDOverlayWindow?
    private let hudViewModel = HUDViewModel()
    private var observationTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?

    /// Begin observing the coordinator and drive the HUD accordingly.
    func start(coordinator: RecordingCoordinator) {
        hudViewModel.observe(coordinator: coordinator)

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await state in await coordinator.stateStream {
                guard !Task.isCancelled else { break }
                self?.handleStateChange(state)
            }
        }
    }

    /// Stop observing and dismiss the HUD.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        dismissTask?.cancel()
        dismissTask = nil
        hudViewModel.stop()
        hudWindow?.orderOut(nil)
        hudWindow = nil
    }

    // MARK: - State handling

    private func handleStateChange(_ state: RecordingState) {
        dismissTask?.cancel()
        dismissTask = nil

        switch state {
        case .recording, .processing:
            showHUD()
        case .injecting:
            showHUD()
            scheduleAutoDismiss()
        case .idle:
            hideHUD()
        }
    }

    private func showHUD() {
        if hudWindow == nil {
            let window = HUDOverlayWindow(viewModel: hudViewModel)
            hudWindow = window
        }
        hudWindow?.showAnimated()
    }

    private func hideHUD() {
        hudWindow?.hideAnimated { [weak self] in
            self?.hudWindow = nil
        }
    }

    /// Dismiss the HUD automatically after a brief delay when injection completes.
    private func scheduleAutoDismiss() {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s
            guard !Task.isCancelled else { return }
            self?.hideHUD()
        }
    }

    deinit {
        observationTask?.cancel()
        dismissTask?.cancel()
    }
}
