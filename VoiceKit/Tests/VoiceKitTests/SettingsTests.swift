import Foundation
import Testing

@testable import VoiceKit

@Suite("Settings", .serialized)
struct SettingsTests {

    // Tests read/write via Settings.shared which uses the standard
    // UserDefaults domain. The suite is serialized to prevent concurrent
    // test runs from interfering with each other. Each test that changes
    // a setting restores the default at the end.

    // MARK: - Sound Feedback

    @Test("Sound feedback defaults to true")
    func soundFeedbackDefault() {
        // Remove any persisted value so we get the registered default.
        UserDefaults.standard.removeObject(forKey: "soundFeedbackEnabled")
        let settings = Settings.shared
        #expect(settings.soundFeedbackEnabled == true)
    }

    @Test("Sound feedback can be set to false")
    func soundFeedbackSetFalse() {
        let settings = Settings.shared
        settings.soundFeedbackEnabled = false
        #expect(settings.soundFeedbackEnabled == false)

        // Restore default.
        settings.soundFeedbackEnabled = true
    }

    @Test("Sound feedback can be toggled back to true")
    func soundFeedbackToggle() {
        let settings = Settings.shared
        settings.soundFeedbackEnabled = false
        #expect(settings.soundFeedbackEnabled == false)

        settings.soundFeedbackEnabled = true
        #expect(settings.soundFeedbackEnabled == true)
    }

    @Test("Sound feedback persists through UserDefaults")
    func soundFeedbackPersistence() {
        let settings = Settings.shared
        settings.soundFeedbackEnabled = false

        // Read directly from UserDefaults to confirm persistence.
        let stored = UserDefaults.standard.bool(forKey: "soundFeedbackEnabled")
        #expect(stored == false)

        // Restore default.
        settings.soundFeedbackEnabled = true
    }

    // MARK: - Hotkey Setting

    @Test("Hotkey defaults to Right Option")
    func hotkeyDefault() {
        // Remove any persisted value so we get the default.
        UserDefaults.standard.removeObject(forKey: "hotkeyConfiguration")
        let settings = Settings.shared
        let hotkey = settings.hotkeySetting

        #expect(hotkey.type == .modifierOnly)
        #expect(hotkey.modifierKey == .rightOption)
    }

    @Test("Hotkey setting can be changed to Left Option")
    func hotkeyChangeToLeftOption() {
        let settings = Settings.shared
        let newSetting = HotkeySetting(modifierKey: .leftOption)
        settings.hotkeySetting = newSetting

        let read = settings.hotkeySetting
        #expect(read.type == .modifierOnly)
        #expect(read.modifierKey == .leftOption)

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Hotkey setting can be changed to Right Command")
    func hotkeyChangeToRightCommand() {
        let settings = Settings.shared
        let newSetting = HotkeySetting(modifierKey: .rightCommand)
        settings.hotkeySetting = newSetting

        let read = settings.hotkeySetting
        #expect(read.modifierKey == .rightCommand)

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Hotkey setting round-trips modifier+key through Settings")
    func hotkeyModifierPlusKeyRoundTrip() {
        let settings = Settings.shared
        let flags: UInt = 0x0010_0000 | 0x0002_0000
        let newSetting = HotkeySetting(
            modifierFlags: flags,
            keyCode: 2,
            keyName: "D"
        )
        settings.hotkeySetting = newSetting

        let read = settings.hotkeySetting
        #expect(read.type == .modifierPlusKey)
        #expect(read.modifierFlags == flags)
        #expect(read.keyCode == UInt16(2))
        #expect(read.keyName == "D")

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Hotkey setting persists through UserDefaults")
    func hotkeyPersistence() {
        let settings = Settings.shared
        let newSetting = HotkeySetting(modifierKey: .leftCommand)
        settings.hotkeySetting = newSetting

        // Read directly from UserDefaults and decode.
        guard let data = UserDefaults.standard.data(forKey: "hotkeyConfiguration"),
            let decoded = try? JSONDecoder().decode(HotkeySetting.self, from: data)
        else {
            Issue.record("Hotkey setting not found in UserDefaults")
            settings.hotkeySetting = .default
            return
        }
        #expect(decoded.modifierKey == .leftCommand)

        // Restore default.
        settings.hotkeySetting = .default
    }

    @Test("Removing hotkey UserDefaults key falls back to default")
    func hotkeyFallbackAfterRemoval() {
        let settings = Settings.shared
        settings.hotkeySetting = HotkeySetting(modifierKey: .leftShift)
        #expect(settings.hotkeySetting.modifierKey == .leftShift)

        // Remove the persisted key.
        UserDefaults.standard.removeObject(forKey: "hotkeyConfiguration")

        // Should fall back to Right Option default.
        let fallback = settings.hotkeySetting
        #expect(fallback.type == .modifierOnly)
        #expect(fallback.modifierKey == .rightOption)
    }

    @Test("Corrupted hotkey data falls back to default")
    func hotkeyCorruptedDataFallback() {
        // Write invalid JSON data to the key.
        let garbage = Data("not valid json".utf8)
        UserDefaults.standard.set(garbage, forKey: "hotkeyConfiguration")

        let settings = Settings.shared
        let hotkey = settings.hotkeySetting
        #expect(hotkey.type == .modifierOnly)
        #expect(hotkey.modifierKey == .rightOption)

        // Clean up.
        UserDefaults.standard.removeObject(forKey: "hotkeyConfiguration")
    }

    // MARK: - Notification

    @Test("Setting sound feedback posts settingsDidChange notification")
    func soundFeedbackNotification() {
        let settings = Settings.shared

        // NotificationCenter.default.post delivers synchronously on the
        // calling thread, so a simple flag works without async.
        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.soundFeedbackEnabled = false

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "soundFeedbackEnabled")

        // Restore default.
        settings.soundFeedbackEnabled = true
    }

    @Test("Setting hotkey posts settingsDidChange notification")
    func hotkeyNotification() {
        let settings = Settings.shared

        var receivedKey: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: settings,
            queue: nil
        ) { notification in
            if receivedKey == nil {
                receivedKey = notification.userInfo?["key"] as? String
            }
        }

        settings.hotkeySetting = HotkeySetting(modifierKey: .leftOption)

        NotificationCenter.default.removeObserver(observer)

        #expect(receivedKey == "hotkeyConfiguration")

        // Restore default.
        settings.hotkeySetting = .default
    }

    // MARK: - Settings is singleton

    @Test("Settings.shared always returns the same instance")
    func singletonIdentity() {
        let a = Settings.shared
        let b = Settings.shared
        #expect(a === b)
    }
}
