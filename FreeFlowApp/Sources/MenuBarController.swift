import AppKit
import FreeFlowKit
import Sparkle

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

    private weak var coordinator: RecordingCoordinator?
    private weak var pipeline: DictationPipeline?
    private var transcriptBuffer: TranscriptBuffer?
    private var textInjector: (any TextInjecting)?
    private var audioDeviceProvider: (any AudioDeviceProviding)?
    private var updaterService: UpdaterService?
    private var shortcuts: ShortcutConfiguration = .default

    /// Callback invoked when Settings menu item is clicked.
    var onOpenSettings: (() -> Void)?

    /// Callback invoked when People menu item is clicked.
    var onOpenPeople: (() -> Void)?

    /// Callback invoked when the user clicks "Sign Out".
    var onSignOut: (() -> Void)?

    /// Callback invoked when an invited user clicks "Disconnect".
    var onDisconnect: (() -> Void)?

    /// Whether the current signed-in user is an admin (provisioned the
    /// server) or an invitee. Admins see "Sign Out"; invitees see
    /// "Disconnect". Defaults to true so the menu shows "Sign Out"
    /// until the app determines the actual role.
    private var isAdmin: Bool = true

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
    private var languageSubmenuItem: NSMenuItem?
    private var checkForUpdatesItem: NSMenuItem?
    private var accountMenuItem: NSMenuItem?
    private var signOutItem: NSMenuItem?
    private var disconnectItem: NSMenuItem?

    /// The email address shown in the menu bar for the signed-in user.
    private var signedInEmail: String?

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
        pipeline: DictationPipeline? = nil,
        transcriptBuffer: TranscriptBuffer? = nil,
        textInjector: (any TextInjecting)? = nil,
        audioDeviceProvider: (any AudioDeviceProviding)? = nil,
        updaterService: UpdaterService? = nil,
        shortcuts: ShortcutConfiguration = .default,
        hotkeyRegistered: Bool = false
    ) {
        self.statusItem = statusItem
        self.coordinator = coordinator
        self.pipeline = pipeline
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

    /// Update whether the hotkey is registered.
    func setHotkeyRegistered(_ registered: Bool) {
        hotkeyRegistered = registered
    }

    /// Update the signed-in email shown in the menu bar.
    ///
    /// Pass `nil` to hide the account section. The menu items update
    /// in place without rebuilding the entire menu.
    func setSignedInEmail(_ email: String?) {
        signedInEmail = email
        accountMenuItem?.title = email ?? ""
        accountMenuItem?.isHidden = email == nil
        signOutItem?.isHidden = email == nil || !isAdmin
        disconnectItem?.isHidden = email == nil || isAdmin
    }

    /// Update the admin/invitee role flag and refresh menu visibility.
    func setIsAdmin(_ admin: Bool) {
        isAdmin = admin
        signOutItem?.isHidden = signedInEmail == nil || !isAdmin
        disconnectItem?.isHidden = signedInEmail == nil || isAdmin
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
            title: "Finish setting up FreeFlow",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        hint.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(hint)

        menu.addItem(.separator())

        let openSetup = NSMenuItem(
            title: "Open Setup…",
            action: #selector(reopenOnboarding),
            keyEquivalent: ""
        )
        openSetup.target = self
        openSetup.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(openSetup)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit FreeFlow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func buildMenu(for statusItem: NSStatusItem) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // --- Account ---

        let account = NSMenuItem(
            title: signedInEmail ?? "",
            action: nil,
            keyEquivalent: ""
        )
        account.isEnabled = false
        account.image = NSImage(systemSymbolName: "person.circle", accessibilityDescription: nil)
        account.isHidden = signedInEmail == nil
        menu.addItem(account)
        accountMenuItem = account

        menu.addItem(.separator())

        // --- Primary actions ---

        let paste = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscript),
            keyEquivalent: "v"
        )
        paste.keyEquivalentModifierMask = [.control, .option]
        paste.target = self
        paste.isEnabled = false
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(paste)
        pasteItem = paste

        menu.addItem(.separator())

        // --- Input ---

        let micSubmenu = NSMenu()
        let micItem = NSMenuItem(
            title: "Microphone",
            action: nil,
            keyEquivalent: ""
        )
        micItem.submenu = micSubmenu
        micItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        menu.addItem(micItem)
        micSubmenuItem = micItem

        let langSubmenu = NSMenu()
        let langItem = NSMenuItem(
            title: "Language",
            action: nil,
            keyEquivalent: ""
        )
        langItem.submenu = langSubmenu
        langItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.addItem(langItem)
        languageSubmenuItem = langItem

        menu.addItem(.separator())

        // --- App ---

        let people = NSMenuItem(
            title: "People…",
            action: #selector(openPeople),
            keyEquivalent: ""
        )
        people.target = self
        people.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        people.isHidden = signedInEmail == nil
        menu.addItem(people)

        let settings = NSMenuItem(
            title: "Preferences…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)

        let checkForUpdates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        checkForUpdates.target = self
        checkForUpdates.isEnabled = updaterService?.canCheckForUpdates ?? false
        checkForUpdates.image = NSImage(
            systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        menu.addItem(checkForUpdates)
        checkForUpdatesItem = checkForUpdates

        let about = NSMenuItem(
            title: "About",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        about.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        menu.addItem(about)

        menu.addItem(.separator())

        // --- Session ---

        let signOut = NSMenuItem(
            title: "Sign Out",
            action: #selector(signOutAction),
            keyEquivalent: ""
        )
        signOut.target = self
        signOut.image = NSImage(
            systemSymbolName: "rectangle.portrait.and.arrow.right",
            accessibilityDescription: nil)
        signOut.isHidden = signedInEmail == nil || !isAdmin
        menu.addItem(signOut)
        signOutItem = signOut

        let disconnect = NSMenuItem(
            title: "Disconnect",
            action: #selector(disconnectAction),
            keyEquivalent: ""
        )
        disconnect.target = self
        disconnect.image = NSImage(
            systemSymbolName: "wifi.slash",
            accessibilityDescription: nil)
        disconnect.isHidden = signedInEmail == nil || isAdmin
        menu.addItem(disconnect)
        disconnectItem = disconnect

        let quit = NSMenuItem(
            title: "Quit FreeFlow",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    /// Refresh dynamic menu items each time the menu opens.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPasteItem()
        refreshMicSubmenu()
        refreshLanguageSubmenu()
        refreshCheckForUpdatesItem()
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

    private func refreshLanguageSubmenu() {
        guard let languageSubmenuItem else { return }
        let submenu = languageSubmenuItem.submenu ?? NSMenu()
        languageSubmenuItem.submenu = submenu
        submenu.removeAllItems()

        let current = LanguageSetting.current

        for setting in LanguageSetting.allCases {
            let item = NSMenuItem(
                title: setting.displayName,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = setting.rawValue
            item.state = (setting == current) ? .on : .off
            submenu.addItem(item)
        }
    }

    private func refreshCheckForUpdatesItem() {
        checkForUpdatesItem?.isEnabled = updaterService?.canCheckForUpdates ?? false
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

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
            let setting = LanguageSetting(rawValue: rawValue)
        else { return }

        LanguageSetting.current = setting

        // Apply the language to the pipeline immediately.
        if let pipeline {
            Task {
                await pipeline.setLanguage(setting.languageCode)
            }
        }

        debugPrint("[MenuBar] Selected language: \(setting.displayName) (\(setting.rawValue))")
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

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func openPeople() {
        onOpenPeople?()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func reopenOnboarding() {
        onReopenOnboarding?()
    }

    @objc private func signOutAction() {
        onSignOut?()
    }

    @objc private func disconnectAction() {
        onDisconnect?()
    }

    // MARK: - Icon mapping

    private func applyIcon(for state: RecordingState) {
        // Static waveform icon for all states. The HUD overlay communicates
        // recording/processing state; the menu bar icon stays simple.
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "FreeFlow"
        )
    }

    deinit {
        observationTask?.cancel()
    }
}
