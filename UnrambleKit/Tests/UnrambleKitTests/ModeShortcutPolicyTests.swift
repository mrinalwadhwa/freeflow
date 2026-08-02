import Testing

@testable import UnrambleKit

@Suite("Mode shortcut policy")
struct ModeShortcutPolicyTests {
    private let policy = ModeShortcutPolicy(
        dictation: .default,
        handsfree: .defaultHandsfree,
        paste: .defaultPaste,
        cancel: .defaultCancel)

    @Test("Default is Control Shift M")
    func newDefault() {
        #expect(
            ShortcutBinding.defaultIncognitoMode
                == ShortcutBinding(
                    kind: .key,
                    modifierFlags: ShortcutBinding.controlFlag
                        | ShortcutBinding.shiftFlag,
                    keyCode: 46,
                    label: "⌃⇧M"))
    }

    @Test("Mode shortcut requires a non-modifier key")
    func requiresKey() {
        let binding = ShortcutBinding(
            kind: .modifierOnly,
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.shiftFlag,
            keyCode: 0,
            label: "⌃⇧")

        #expect(policy.validate(binding) == .requiresKey)
    }

    @Test("Mode shortcut requires two standard modifiers")
    func requiresTwoModifiers() {
        let binding = ShortcutBinding(
            modifierFlags: 0,
            keyCode: 46,
            label: "M")

        #expect(policy.validate(binding) == .requiresTwoModifiers)
    }

    @Test("Physical A remains a key even though its key code is zero")
    func acceptsAKeyCodeZero() {
        let binding = ShortcutBinding(
            kind: .key,
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.shiftFlag,
            keyCode: 0,
            label: "⌃⇧A")

        #expect(policy.validate(binding) == nil)
    }

    @Test("Mode chord rejects modifier-only dictation key as qualifier")
    func modifierFamilyQualifierConflict() {
        let binding = ShortcutBinding(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.optionFlag,
            keyCode: 46,
            label: "⌃⌥M")

        #expect(policy.validate(binding) == .conflictsWithDictation)
    }

    @Test(
        "Mode chord rejects exact command conflicts",
        arguments: [
            (ShortcutBinding.defaultPaste, ModeShortcutValidationError.conflictsWithPaste),
            (ShortcutBinding.defaultCancel, ModeShortcutValidationError.requiresTwoModifiers),
        ])
    func commandConflicts(
        binding: ShortcutBinding,
        expected: ModeShortcutValidationError
    ) {
        #expect(policy.validate(binding) == expected)
    }

    @Test("Mode chord rejects a two-modifier hands-free conflict")
    func handsfreeConflict() {
        let handsfree = ShortcutBinding(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.commandFlag,
            keyCode: 4,
            label: "⌃⌘H")
        let conflictPolicy = ModeShortcutPolicy(
            dictation: .default,
            handsfree: handsfree,
            paste: .defaultPaste,
            cancel: .defaultCancel)

        #expect(conflictPolicy.validate(handsfree) == .conflictsWithHandsfree)
    }

    @Test("Mode chord rejects exact dictation combo")
    func dictationComboConflict() {
        let binding = ShortcutBinding(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.commandFlag,
            keyCode: 37,
            label: "⌃⌘L")
        let comboPolicy = ModeShortcutPolicy(
            dictation: .modifierPlusKey(
                modifierFlags: binding.modifierFlags,
                keyCode: binding.keyCode,
                keyName: "L"),
            handsfree: .defaultHandsfree,
            paste: .defaultPaste,
            cancel: .defaultCancel)

        #expect(comboPolicy.validate(binding) == .conflictsWithDictation)
    }
}
