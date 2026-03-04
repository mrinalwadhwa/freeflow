import AppKit
import VoiceKit

/// Build and manage the menu bar status item, icon, and dropdown menu.
///
/// Observes `RecordingCoordinator.stateStream` to swap the status item icon.
/// Builds a rich menu with paste-last-transcript, microphone selection,
/// status indicator, and quit. Menu items that depend on async state
/// (transcript availability, device list) are refreshed each time the
/// menu opens via `NSMenuDelegate`.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    private weak var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?

    // MARK: - Dependencies

    private var coordinator: RecordingCoordinator?
    private var transcriptBuffer: TranscriptBuffer?
    private var textInjector: (any TextInjecting)?
    private var audioDeviceProvider: (any AudioDeviceProviding)?
    private var shortcuts: ShortcutConfiguration = .default

    // MARK: - Menu items that need dynamic updates

    private var pasteItem: NSMenuItem?
    private var micSubmenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?

    // MARK: - State tracking

    private var currentRecordingState: RecordingState = .idle
    private var hotkeyRegistered: Bool = false

    // MARK: - Lifecycle

    /// Configure and begin observing state to drive the status item.
    ///
    /// - Parameters:
    ///   - statusItem: The menu bar status item to manage.
    ///   - coordinator: The recording coordinator to observe.
    ///   - transcriptBuffer: The buffer holding the last transcript for re-paste.
    ///   - textInjector: The injector used to re-paste transcripts.
    ///   - audioDeviceProvider: The provider for mic enumeration and selection.
    ///   - shortcuts: The shortcut configuration for display hints.
    ///   - hotkeyRegistered: Whether the global hotkey registered successfully.
    func start(
        statusItem: NSStatusItem,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        textInjector: (any TextInjecting)? = nil,
        audioDeviceProvider: (any AudioDeviceProviding)? = nil,
        shortcuts: ShortcutConfiguration = .default,
        hotkeyRegistered: Bool = false
    ) {
        self.statusItem = statusItem
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
        self.textInjector = textInjector
        self.audioDeviceProvider = audioDeviceProvider
        self.shortcuts = shortcuts
        self.hotkeyRegistered = hotkeyRegistered

        buildMenu(for: statusItem)
        applyIcon(for: .idle)

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            for await state in await coordinator.stateStream {
                guard !Task.isCancelled else { break }
                self?.currentRecordingState = state
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

    /// Update whether the hotkey is registered. Refreshes the status line.
    func setHotkeyRegistered(_ registered: Bool) {
        hotkeyRegistered = registered
    }

    // MARK: - Menu construction

    private func buildMenu(for statusItem: NSStatusItem) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // --- Primary actions ---

        let paste = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscript),
            keyEquivalent: "v"
        )
        paste.keyEquivalentModifierMask = [.control, .option]
        paste.target = self
        paste.isEnabled = false
        menu.addItem(paste)
        pasteItem = paste

        menu.addItem(.separator())

        // --- Settings ---

        let micSubmenu = NSMenu()
        let micItem = NSMenuItem(
            title: "Microphone",
            action: nil,
            keyEquivalent: ""
        )
        micItem.submenu = micSubmenu
        menu.addItem(micItem)
        micSubmenuItem = micItem

        menu.addItem(.separator())

        // --- Status ---

        let status = NSMenuItem(
            title: "Status: Idle",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(.separator())

        // --- App ---

        let about = NSMenuItem(
            title: "About Voice",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Refresh dynamic menu items each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPasteItem()
        refreshMicSubmenu()
        refreshStatusItem()
    }

    // MARK: - Dynamic refresh

    private func refreshPasteItem() {
        guard let pasteItem, let transcriptBuffer else {
            pasteItem?.isEnabled = false
            return
        }
        // Check buffer availability synchronously via a detached task that
        // completes before the menu finishes opening. Since TranscriptBuffer
        // is an actor, we fire-and-forget with nonisolated(unsafe) capture.
        // For a menu open this is fast enough.
        let item = pasteItem
        Task {
            let has = await transcriptBuffer.hasTranscript
            item.isEnabled = has
        }
    }

    private func refreshMicSubmenu() {
        guard let micSubmenuItem, let audioDeviceProvider else { return }
        let submenu = micSubmenuItem.submenu ?? NSMenu()
        micSubmenuItem.submenu = submenu

        Task {
            let devices = await audioDeviceProvider.availableDevices()
            let current = await audioDeviceProvider.currentDevice()

            submenu.removeAllItems()

            if devices.isEmpty {
                let none = NSMenuItem(
                    title: "No Input Devices",
                    action: nil,
                    keyEquivalent: ""
                )
                none.isEnabled = false
                submenu.addItem(none)
                return
            }

            for device in devices {
                let item = NSMenuItem(
                    title: device.name,
                    action: #selector(selectMicrophone(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = Int(device.id)
                item.state = (device.id == current?.id) ? .on : .off
                submenu.addItem(item)
            }
        }
    }

    private func refreshStatusItem() {
        guard let statusMenuItem else { return }

        let stateLabel: String
        switch currentRecordingState {
        case .idle:
            stateLabel = "Idle"
        case .recording:
            stateLabel = "Recording"
        case .processing:
            stateLabel = "Processing"
        case .injecting:
            stateLabel = "Injecting"
        case .injectionFailed:
            stateLabel = "No Target"
        }

        let hotkeyLabel = hotkeyRegistered ? "Hotkey: ✓" : "Hotkey: Not registered"
        statusMenuItem.title = "\(stateLabel)  ·  \(hotkeyLabel)"
    }

    // MARK: - Actions

    @objc private func pasteLastTranscript() {
        guard let transcriptBuffer, let textInjector else {
            debugPrint("[MenuBar] Paste requested but buffer or injector not available")
            return
        }
        Task {
            guard let transcript = await transcriptBuffer.consume() else {
                debugPrint("[MenuBar] No transcript in buffer to paste")
                return
            }

            // Read context at the moment of paste for accurate injection.
            let context = AppContext.empty

            do {
                try await textInjector.inject(text: transcript, into: context)
                debugPrint("[MenuBar] Pasted last transcript (\(transcript.count) chars)")
            } catch {
                debugPrint("[MenuBar] Paste injection failed: \(error)")
                // Re-store the transcript so the user can try again.
                await transcriptBuffer.store(transcript)
            }

            // If the coordinator is in injectionFailed, reset to idle after
            // a successful paste.
            if let coordinator, await coordinator.state == .injectionFailed {
                await coordinator.reset()
            }
        }
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard let audioDeviceProvider else { return }
        let deviceID = UInt32(sender.tag)
        Task {
            do {
                try await audioDeviceProvider.selectDevice(id: deviceID)
                debugPrint("[MenuBar] Selected microphone: \(sender.title) (id: \(deviceID))")
            } catch {
                debugPrint("[MenuBar] Failed to select microphone: \(error)")
            }
        }
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
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
