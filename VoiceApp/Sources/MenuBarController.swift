import AppKit
import VoiceKit

/// Update the menu bar status item icon to reflect the current recording state.
///
/// Observes a `RecordingCoordinator`'s state stream and swaps the status
/// item's image between idle (waveform), recording (red waveform circle),
/// and processing (ellipsis circle) icons.
@MainActor
final class MenuBarController {

    private weak var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?

    /// Begin observing the coordinator and update the given status item.
    func start(statusItem: NSStatusItem, coordinator: RecordingCoordinator) {
        self.statusItem = statusItem
        applyIcon(for: .idle)

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await state in await coordinator.stateStream {
                guard !Task.isCancelled else { break }
                self?.applyIcon(for: state)
            }
        }
    }

    /// Stop observing and reset the icon to idle.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        applyIcon(for: .idle)
    }

    // MARK: - Icon mapping

    private func applyIcon(for state: RecordingState) {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let accessibilityLabel: String

        switch state {
        case .idle:
            symbolName = "waveform"
            accessibilityLabel = "Voice — Idle"
        case .recording:
            symbolName = "record.circle"
            accessibilityLabel = "Voice — Recording"
        case .processing:
            symbolName = "ellipsis.circle"
            accessibilityLabel = "Voice — Processing"
        case .injecting:
            symbolName = "text.cursor"
            accessibilityLabel = "Voice — Injecting"
        case .injectionFailed:
            symbolName = "exclamationmark.triangle"
            accessibilityLabel = "Voice — No Target"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )

        // Tint the recording icon red so it stands out.
        if state == .recording {
            let config = NSImage.SymbolConfiguration(
                paletteColors: [.systemRed]
            )
            button.image = image?.withSymbolConfiguration(config)
        } else {
            button.image = image
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
