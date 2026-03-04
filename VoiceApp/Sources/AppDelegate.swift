import AppKit
import SwiftUI
import VoiceKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
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

    // MARK: - Actions

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
