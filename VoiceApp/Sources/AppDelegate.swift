import AppKit
import SwiftUI
import VoiceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    // MARK: - Services

    private let coordinator = RecordingCoordinator()
    private let permissionProvider = MicrophonePermissionProvider()
    private let hotkeyProvider = CGEventTapHotkeyProvider()
    private var pipeline: DictationPipeline?

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPipeline()
        setupHUD()
        setupMenuBarState()
        checkPermissions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyProvider.unregister()
        hudController?.stop()
        menuBarController?.stop()
        permissionController?.stop()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Voice"
            )
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "About Voice",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit Voice",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu

        self.statusItem = statusItem
        self.menu = menu
    }

    // MARK: - Pipeline

    private func setupPipeline() {
        pipeline = DictationPipeline(
            audioProvider: AudioCaptureProvider(),
            contextProvider: AXAppContextProvider(),
            sttProvider: VoiceServiceSTTProvider(),
            textInjector: AppTextInjector(),
            coordinator: coordinator
        )
    }

    // MARK: - HUD

    private func setupHUD() {
        let controller = HUDController()
        controller.start(coordinator: coordinator)
        hudController = controller
    }

    // MARK: - Menu Bar State

    private func setupMenuBarState() {
        guard let statusItem else { return }
        let controller = MenuBarController()
        controller.start(statusItem: statusItem, coordinator: coordinator)
        menuBarController = controller
    }

    // MARK: - Permissions

    private func checkPermissions() {
        let controller = PermissionController(permissionProvider: permissionProvider)
        controller.onPermissionsGranted = { [weak self] in
            self?.registerHotkey()
        }
        permissionController = controller
        controller.checkPermissions()
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        guard let pipeline else {
            debugPrint("[AppDelegate] Pipeline not initialized, cannot register hotkey")
            return
        }

        let pipelineRef = pipeline

        do {
            try hotkeyProvider.register { event in
                Task {
                    switch event {
                    case .pressed:
                        debugPrint("[Hotkey] Right Option pressed — activating pipeline")
                        await pipelineRef.activate()
                    case .released:
                        debugPrint("[Hotkey] Right Option released — completing pipeline")
                        await pipelineRef.complete()
                    }
                }
            }
            debugPrint("[AppDelegate] Global hotkey registered (Right Option)")
        } catch {
            debugPrint("[AppDelegate] Failed to register hotkey: \(error)")
            Task { @MainActor in
                self.showHotkeyRegistrationFailedAlert(error: error)
            }
        }
    }

    // MARK: - Alerts

    @MainActor
    private func showHotkeyRegistrationFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Hotkey Registration Failed"
        alert.informativeText = """
            Voice could not register the global hotkey (Right Option). \
            \(error). \
            Try granting accessibility access and restarting the app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            permissionProvider.openAccessibilitySettings()
        }
    }

    // MARK: - Actions

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
