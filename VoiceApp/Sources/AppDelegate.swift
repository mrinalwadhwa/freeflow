import AppKit
import SwiftUI
import VoiceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    // MARK: - Services

    private let coordinator = RecordingCoordinator()
    private let permissionProvider = MicrophonePermissionProvider()
    private let hotkeyProvider = CGEventTapHotkeyProvider()
    private let transcriptBuffer = TranscriptBuffer()
    private let textInjector = AppTextInjector()
    private var pipeline: DictationPipeline?

    // MARK: - Controllers

    private var hudController: HUDController?
    private var menuBarController: MenuBarController?
    private var permissionController: PermissionController?
    private var doubleTapDetector: DoubleTapDetector?

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

        self.statusItem = statusItem
    }

    // MARK: - Pipeline

    private let audioProvider = AudioCaptureProvider()

    private func setupPipeline() {
        pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: AXAppContextProvider(),
            dictationProvider: VoiceServiceDictationProvider(),
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: VoiceServiceStreamingProvider()
        )
    }

    // MARK: - HUD

    private func setupHUD() {
        let controller = HUDController()
        controller.start(coordinator: coordinator, pipeline: pipeline, audioProvider: audioProvider)
        hudController = controller
    }

    // MARK: - Menu Bar State

    private func setupMenuBarState() {
        guard let statusItem else { return }
        let controller = MenuBarController()
        controller.start(
            statusItem: statusItem,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            textInjector: textInjector,
            shortcuts: .default
        )
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
        let hudRef = hudController
        let menuRef = menuBarController

        let detector = DoubleTapDetector(
            doubleTapInterval: ShortcutConfiguration.default.doubleTapInterval)

        detector.onGesture = { gesture in
            switch gesture {
            case .hold:
                debugPrint("[Hotkey] Hold detected — push-to-talk")
                hudRef?.hotkeyHeld()
                Task { await pipelineRef.activate() }
            case .doubleTap:
                debugPrint("[Hotkey] Double-tap detected — hands-free toggle")
                hudRef?.toggledHandsFree()
                Task { await pipelineRef.activate() }
            }
        }

        detector.onHoldRelease = {
            debugPrint("[Hotkey] Hold released — completing pipeline")
            Task { await pipelineRef.complete() }
        }

        self.doubleTapDetector = detector

        do {
            try hotkeyProvider.register { [weak detector] event in
                Task { @MainActor in
                    detector?.handleEvent(event)
                }
            }
            menuRef?.setHotkeyRegistered(true)
            debugPrint("[AppDelegate] Global hotkey registered (Right Option)")
        } catch {
            debugPrint("[AppDelegate] Failed to register hotkey: \(error)")
            menuRef?.setHotkeyRegistered(false)
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
}
