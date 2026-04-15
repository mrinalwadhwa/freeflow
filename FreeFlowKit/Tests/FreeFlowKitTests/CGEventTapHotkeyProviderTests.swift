import Foundation
import Testing

@testable import FreeFlowKit

@Suite("CGEventTapHotkeyProvider")
struct CGEventTapHotkeyProviderTests {

    @Test("Unregister clears the retained self-pointer")
    func unregisterClearsSelfPointer() {
        let provider = CGEventTapHotkeyProvider()

        // Before registration, no retained pointer exists.
        #expect(provider.retainedSelfPointer == nil)

        // Try to register. This will fail without accessibility permission,
        // which is expected in CI/test environments.
        do {
            try provider.register { _ in }
            // Registration succeeded — a retained pointer should exist.
            #expect(provider.retainedSelfPointer != nil)

            provider.unregister()

            // After unregister, the retained pointer must be released.
            #expect(
                provider.retainedSelfPointer == nil,
                "tearDownTap must release the retained self-pointer")
        } catch {
            // Accessibility not granted — tap creation failed.
            // Verify no pointer was leaked.
            #expect(provider.retainedSelfPointer == nil)
        }
    }

    @Test("Double unregister does not crash")
    func doubleUnregister() {
        let provider = CGEventTapHotkeyProvider()
        try? provider.register { _ in }
        provider.unregister()
        provider.unregister()
        // No crash = success.
    }
}
