import Foundation
import Testing

@testable import FreeFlowKit

@Suite("HotkeySetting")
struct HotkeySettingTests {

    // MARK: - Modifier-only initializer

    @Test("Modifier-only init sets correct type and key")
    func modifierOnlyInit() {
        let setting = HotkeySetting(modifierKey: .rightOption)

        #expect(setting.type == .modifierOnly)
        #expect(setting.modifierKey == .rightOption)
        #expect(setting.modifierFlags == nil)
        #expect(setting.keyCode == nil)
        #expect(setting.keyName == nil)
    }

    @Test("Modifier+key init sets correct type and values")
    func modifierPlusKeyInit() {
        let expectedFlags: UInt = 0x0010_0000 | 0x0002_0000
        let setting = HotkeySetting(
            modifierFlags: expectedFlags,
            keyCode: 2,
            keyName: "D"
        )

        #expect(setting.type == .modifierPlusKey)
        #expect(setting.modifierKey == nil)
        #expect(setting.modifierFlags == expectedFlags)
        #expect(setting.keyCode == UInt16(2))
        #expect(setting.keyName == "D")
    }

    // MARK: - Display names

    @Test("Right Option display name")
    func rightOptionDisplayName() {
        let setting = HotkeySetting(modifierKey: .rightOption)
        #expect(setting.displayName == "Right Option ⌥")
    }

    @Test("Left Command display name")
    func leftCommandDisplayName() {
        let setting = HotkeySetting(modifierKey: .leftCommand)
        #expect(setting.displayName == "Left Command ⌘")
    }

    @Test("Right Control display name")
    func rightControlDisplayName() {
        let setting = HotkeySetting(modifierKey: .rightControl)
        #expect(setting.displayName == "Right Control ⌃")
    }

    @Test("Right Shift display name")
    func rightShiftDisplayName() {
        let setting = HotkeySetting(modifierKey: .rightShift)
        #expect(setting.displayName == "Right Shift ⇧")
    }

    @Test("Modifier+key display name shows modifiers then key")
    func modifierPlusKeyDisplayName() {
        // Command (0x0010_0000) + Shift (0x0002_0000) + D
        let flags: UInt = 0x0010_0000 | 0x0002_0000
        let setting = HotkeySetting(
            modifierFlags: flags,
            keyCode: 2,
            keyName: "D"
        )
        #expect(setting.displayName == "⇧⌘D")
    }

    @Test("Modifier+key display name with Control+Option")
    func controlOptionKeyDisplayName() {
        // Control (0x0004_0000) + Option (0x0008_0000) + V
        let flags: UInt = 0x0004_0000 | 0x0008_0000
        let setting = HotkeySetting(
            modifierFlags: flags,
            keyCode: 9,
            keyName: "V"
        )
        #expect(setting.displayName == "⌃⌥V")
    }

    // MARK: - Device flags

    @Test("All modifier keys have distinct device flags")
    func distinctDeviceFlags() {
        let allFlags = HotkeySetting.ModifierKey.allCases.map(\.deviceFlag)
        let uniqueFlags = Set(allFlags)
        #expect(uniqueFlags.count == allFlags.count)
    }

    @Test("Right Option device flag is 0x40")
    func rightOptionDeviceFlag() {
        #expect(HotkeySetting.ModifierKey.rightOption.deviceFlag == 0x0000_0040)
    }

    @Test("Left Option device flag is 0x20")
    func leftOptionDeviceFlag() {
        #expect(HotkeySetting.ModifierKey.leftOption.deviceFlag == 0x0000_0020)
    }

    @Test("Right Command device flag is 0x10")
    func rightCommandDeviceFlag() {
        #expect(HotkeySetting.ModifierKey.rightCommand.deviceFlag == 0x0000_0010)
    }

    @Test("Left Command device flag is 0x08")
    func leftCommandDeviceFlag() {
        #expect(HotkeySetting.ModifierKey.leftCommand.deviceFlag == 0x0000_0008)
    }

    // MARK: - Symbols

    @Test("Option modifier keys use option symbol")
    func optionSymbol() {
        #expect(HotkeySetting.ModifierKey.rightOption.symbol == "⌥")
        #expect(HotkeySetting.ModifierKey.leftOption.symbol == "⌥")
    }

    @Test("Command modifier keys use command symbol")
    func commandSymbol() {
        #expect(HotkeySetting.ModifierKey.rightCommand.symbol == "⌘")
        #expect(HotkeySetting.ModifierKey.leftCommand.symbol == "⌘")
    }

    @Test("Control modifier keys use control symbol")
    func controlSymbol() {
        #expect(HotkeySetting.ModifierKey.rightControl.symbol == "⌃")
        #expect(HotkeySetting.ModifierKey.leftControl.symbol == "⌃")
    }

    @Test("Shift modifier keys use shift symbol")
    func shiftSymbol() {
        #expect(HotkeySetting.ModifierKey.rightShift.symbol == "⇧")
        #expect(HotkeySetting.ModifierKey.leftShift.symbol == "⇧")
    }

    // MARK: - Equatable

    @Test("Same modifier-only settings are equal")
    func equalModifierOnly() {
        let a = HotkeySetting(modifierKey: .rightOption)
        let b = HotkeySetting(modifierKey: .rightOption)
        #expect(a == b)
    }

    @Test("Different modifier-only settings are not equal")
    func notEqualModifierOnly() {
        let a = HotkeySetting(modifierKey: .rightOption)
        let b = HotkeySetting(modifierKey: .leftOption)
        #expect(a != b)
    }

    @Test("Same modifier+key settings are equal")
    func equalModifierPlusKey() {
        let flags: UInt = 0x0010_0000
        let a = HotkeySetting(modifierFlags: flags, keyCode: 2, keyName: "D")
        let b = HotkeySetting(modifierFlags: flags, keyCode: 2, keyName: "D")
        #expect(a == b)
    }

    @Test("Modifier-only and modifier+key settings are not equal")
    func notEqualDifferentTypes() {
        let a = HotkeySetting(modifierKey: .rightOption)
        let flags: UInt = 0x0008_0000
        let b = HotkeySetting(modifierFlags: flags, keyCode: 2, keyName: "D")
        #expect(a != b)
    }

    // MARK: - Codable round-trip

    @Test("Modifier-only setting round-trips through JSON")
    func codableModifierOnly() throws {
        let original = HotkeySetting(modifierKey: .leftCommand)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeySetting.self, from: data)
        #expect(decoded == original)
    }

    @Test("Modifier+key setting round-trips through JSON")
    func codableModifierPlusKey() throws {
        let flags: UInt = 0x0010_0000 | 0x0002_0000
        let original = HotkeySetting(
            modifierFlags: flags,
            keyCode: 2,
            keyName: "D"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeySetting.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Presets

    @Test("Default preset is Right Option")
    func defaultPreset() {
        let preset = HotkeySetting.default
        #expect(preset.type == .modifierOnly)
        #expect(preset.modifierKey == .rightOption)
    }

    @Test("Named presets match expected modifiers")
    func namedPresets() {
        #expect(HotkeySetting.rightOption.modifierKey == .rightOption)
        #expect(HotkeySetting.leftOption.modifierKey == .leftOption)
        #expect(HotkeySetting.rightCommand.modifierKey == .rightCommand)
        #expect(HotkeySetting.rightControl.modifierKey == .rightControl)
    }

    // MARK: - Hint text

    @Test("Modifier-only hint text includes symbol and name")
    func modifierOnlyHintText() {
        let setting = HotkeySetting(modifierKey: .rightOption)
        let hint = setting.hintText
        #expect(hint.contains("⌥"))
        #expect(hint.contains("Right Option"))
    }

    @Test("Modifier+key hint text matches display name")
    func modifierPlusKeyHintText() {
        let flags: UInt = 0x0010_0000
        let setting = HotkeySetting(
            modifierFlags: flags,
            keyCode: 2,
            keyName: "D"
        )
        #expect(setting.hintText == setting.displayName)
    }

    // MARK: - All modifier keys are iterable

    @Test("ModifierKey has 8 cases")
    func allModifierKeys() {
        #expect(HotkeySetting.ModifierKey.allCases.count == 8)
    }

    @Test("Every modifier key has a non-empty display name")
    func allDisplayNames() {
        for key in HotkeySetting.ModifierKey.allCases {
            #expect(!key.displayName.isEmpty)
        }
    }

    @Test("Every modifier key has a non-zero device flag")
    func allDeviceFlags() {
        for key in HotkeySetting.ModifierKey.allCases {
            #expect(key.deviceFlag != 0)
        }
    }
}
