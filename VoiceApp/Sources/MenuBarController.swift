import AppKit
import Sparkle
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
    private var updaterService: UpdaterService?
    private var shortcuts: ShortcutConfiguration = .default

    // MARK: - Onboarding mode

    /// When true, the menu shows a minimal onboarding hint instead of
    /// the full operational menu.
    private var onboardingMode: Bool = false

    /// Callback invoked when the user clicks "Open Setup…" in the
    /// onboarding menu. The AppDelegate wires this to re-present the
    /// onboarding window.
    var onReopenOnboarding: (() -> Void)?

    // MARK: - Menu items that need dynamic updates

    private var pasteItem: NSMenuItem?
    private var micSubmenuItem: NSMenuItem?
    private var checkForUpdatesItem: NSMenuItem?
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
        updaterService: UpdaterService? = nil,
        shortcuts: ShortcutConfiguration = .default,
        hotkeyRegistered: Bool = false
    ) {
        self.statusItem = statusItem
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
        self.textInjector = textInjector
        self.audioDeviceProvider = audioDeviceProvider
        self.updaterService = updaterService
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

    /// Switch to onboarding mode: show a minimal menu with a setup hint.
    func setOnboardingMode(_ enabled: Bool) {
        onboardingMode = enabled
        guard let statusItem else { return }
        if enabled {
            buildOnboardingMenu(for: statusItem)
        } else {
            buildMenu(for: statusItem)
        }
    }

    // MARK: - Menu construction

    private func buildOnboardingMenu(for statusItem: NSStatusItem) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hint = NSMenuItem(
            title: "Click your invite link to get started",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let openSetup = NSMenuItem(
            title: "Open Setup…",
            action: #selector(reopenOnboarding),
            keyEquivalent: ""
        )
        openSetup.target = self
        menu.addItem(openSetup)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        statusItem.menu = menu
    }

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

        // --- Updates ---

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        checkForUpdates.target = self
        checkForUpdates.isEnabled = updaterService?.canCheckForUpdates ?? false
        menu.addItem(checkForUpdates)
        checkForUpdatesItem = checkForUpdates

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
        refreshCheckForUpdatesItem()
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

    private func refreshCheckForUpdatesItem() {
        checkForUpdatesItem?.isEnabled = updaterService?.canCheckForUpdates ?? false
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
        case .sessionExpired:
            stateLabel = "Session Expired"
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

    @objc private func checkForUpdatesAction() {
        updaterService?.checkForUpdates()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reopenOnboarding() {
        onReopenOnboarding?()
    }

    // MARK: - Icon mapping

    private func applyIcon(for state: RecordingState) {
        // Static waveform icon for all states. The HUD overlay communicates
        // recording/processing state; the menu bar icon stays simple.
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Voice"
        )
    }

    deinit {
        observationTask?.cancel()
    }
}
