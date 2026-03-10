import Foundation
import Testing

@testable import VoiceKit

@Suite("ShortcutConfiguration")
struct ShortcutConfigurationTests {

    @Test("Default configuration has expected key names")
    func defaultValues() {
        let config = ShortcutConfiguration.default

        // holdToRecordKeyName is now dynamic, read from HotkeySetting.current.
        // With default settings it should reflect Right Option.
        #expect(config.holdToRecordKeyName == HotkeySetting.current.displayName)
        #expect(config.pasteShortcutName == "⌃⌥V")
        #expect(config.dismissKeyName == "Escape")
    }

    @Test("Static default matches parameterless init")
    func staticDefaultMatchesInit() {
        let config = ShortcutConfiguration()
        #expect(config == .default)
    }

    @Test("Custom configuration preserves paste and dismiss values")
    func customValues() {
        let config = ShortcutConfiguration(
            pasteShortcutName: "⌘⇧V",
            dismissKeyName: "Esc"
        )

        #expect(config.pasteShortcutName == "⌘⇧V")
        #expect(config.dismissKeyName == "Esc")
    }

    @Test("Hold-to-record hint includes key name from HotkeySetting")
    func holdToRecordHint() {
        let config = ShortcutConfiguration.default
        let expected = "Hold \(HotkeySetting.current.displayName) to dictate"
        #expect(config.holdToRecordHint == expected)
    }

    @Test("No-target hint includes paste shortcut")
    func noTargetHint() {
        let config = ShortcutConfiguration.default
        #expect(config.noTargetHint == "Select a text field, then ⌃⌥V to paste")
    }

    @Test("No-target hint reflects custom paste shortcut")
    func noTargetHintCustom() {
        let config = ShortcutConfiguration(pasteShortcutName: "⌘⇧V")
        #expect(config.noTargetHint == "Select a text field, then ⌘⇧V to paste")
    }

    @Test("Equatable compares paste and dismiss fields")
    func equatable() {
        let a = ShortcutConfiguration.default
        let b = ShortcutConfiguration(pasteShortcutName: "⌘⇧V")
        #expect(a != b)
    }
}
