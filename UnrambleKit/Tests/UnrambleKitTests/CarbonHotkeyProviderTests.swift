import Carbon.HIToolbox
import Testing

@testable import UnrambleKit

@Suite("CarbonHotkeyProvider")
struct CarbonHotkeyProviderTests {
    @Test("Maps standard shortcut modifiers to Carbon flags")
    func mapsStandardShortcutModifiers() throws {
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.optionFlag
                | ShortcutBinding.shiftFlag
                | ShortcutBinding.commandFlag,
            keyCode: 46,
            keyName: "M")

        let descriptor = try CarbonHotkeyProvider.descriptor(for: setting)

        #expect(descriptor.keyCode == 46)
        #expect(
            descriptor.modifiers
                == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }

    @Test("Ignores nonstandard modifier bits")
    func ignoresNonstandardModifierBits() throws {
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.shiftFlag
                | 0x0080_0000,
            keyCode: 4,
            keyName: "H")

        let descriptor = try CarbonHotkeyProvider.descriptor(for: setting)

        #expect(descriptor.keyCode == 4)
        #expect(descriptor.modifiers == UInt32(controlKey | shiftKey))
    }

    @Test("Rejects modifier-only shortcuts")
    func rejectsModifierOnlyShortcuts() {
        #expect(throws: CarbonHotkeyRegistrationError.self) {
            try CarbonHotkeyProvider.descriptor(for: .rightOption)
        }
    }

    @Test("Supports an unmodified key")
    func supportsUnmodifiedKey() throws {
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: 0,
            keyCode: 36,
            keyName: "Return")

        let descriptor = try CarbonHotkeyProvider.descriptor(for: setting)

        #expect(descriptor.keyCode == 36)
        #expect(descriptor.modifiers == 0)
    }
}
