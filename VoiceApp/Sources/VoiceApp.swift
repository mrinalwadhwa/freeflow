import SwiftUI
import VoiceKit

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app only — no windows. Settings can be added later.
        Settings {
            EmptyView()
        }
    }
}
