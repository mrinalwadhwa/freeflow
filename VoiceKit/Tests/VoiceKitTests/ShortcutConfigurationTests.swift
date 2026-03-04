import Foundation
import Testing

@testable import VoiceKit

@Suite("ShortcutConfiguration")
struct ShortcutConfigurationTests {

    @Test("Default configuration has expected key names")
    func defaultValues() {
        let config = ShortcutConfiguration.default

        #expect(config.holdToRecordKeyName == "⌥ Right Option")
        #expect(config.handsFreeToggleName == "Double-tap ⌥ Right Option")
        #expect(config.pasteShortcutName == "⌃⌥V")
        #expect(config.dismissKeyName == "Escape")
        #expect(config.doubleTapInterval == 0.35)
    }

    @Test("Static default matches parameterless init")
    func staticDefaultMatchesInit() {
        let config = ShortcutConfiguration()
        #expect(config == .default)
    }

    @Test("Custom configuration preserves all values")
    func customValues() {
        let config = ShortcutConfiguration(
            holdToRecordKeyName: "fn",
            handsFreeToggleName: "Double-tap fn",
            doubleTapInterval: 0.4,
            pasteShortcutName: "⌘⇧V",
            dismissKeyName: "Esc"
        )

        #expect(config.holdToRecordKeyName == "fn")
        #expect(config.handsFreeToggleName == "Double-tap fn")
        #expect(config.doubleTapInterval == 0.4)
        #expect(config.pasteShortcutName == "⌘⇧V")
        #expect(config.dismissKeyName == "Esc")
    }

    @Test("Hold-to-record hint includes key name")
    func holdToRecordHint() {
        let config = ShortcutConfiguration.default
        #expect(config.holdToRecordHint == "Hold ⌥ Right Option to dictate")
    }

    @Test("Hold-to-record hint reflects custom key name")
    func holdToRecordHintCustom() {
        let config = ShortcutConfiguration(holdToRecordKeyName: "fn")
        #expect(config.holdToRecordHint == "Hold fn to dictate")
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

    @Test("Equatable distinguishes different configurations")
    func equatable() {
        let a = ShortcutConfiguration.default
        let b = ShortcutConfiguration(doubleTapInterval: 0.5)
        #expect(a != b)
    }
}
