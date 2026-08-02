import Carbon.HIToolbox
import Foundation
import Testing

@testable import UnrambleKit

@Suite("CarbonHotkeyProvider system adapter", .serialized)
struct CarbonHotkeyProviderOSTests {
    @Test("Delivers registered press and release events")
    @MainActor
    func deliversRegisteredPressAndReleaseEvents() throws {
        let recorder = CarbonHotkeyEventRecorder()
        let provider = CarbonHotkeyProvider()
        let setting = HotkeySetting.modifierPlusKey(
            modifierFlags: ShortcutBinding.controlFlag
                | ShortcutBinding.optionFlag
                | ShortcutBinding.shiftFlag
                | ShortcutBinding.commandFlag,
            keyCode: UInt16(kVK_F18),
            keyName: "F18")

        try provider.register(with: setting) { event in
            recorder.append(event)
        }
        defer { provider.unregister() }

        try sendHotkeyEvent(
            kind: UInt32(kEventHotKeyPressed),
            identity: provider.registrationIdentityForTesting)
        try sendHotkeyEvent(
            kind: UInt32(kEventHotKeyReleased),
            identity: provider.registrationIdentityForTesting)

        #expect(recorder.events == [.pressed, .released])
    }

    @MainActor
    private func sendHotkeyEvent(
        kind: UInt32,
        identity: EventHotKeyID
    ) throws {
        var event: EventRef?
        let createStatus = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            kind,
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone),
            &event)
        guard createStatus == noErr, let event else {
            throw CarbonHotkeyOSTestError.createEventFailed(createStatus)
        }
        defer { ReleaseEvent(event) }

        var identity = identity
        let parameterStatus = SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &identity)
        guard parameterStatus == noErr else {
            throw CarbonHotkeyOSTestError.setParameterFailed(
                parameterStatus)
        }

        let deliveryStatus = SendEventToEventTarget(
            event,
            GetApplicationEventTarget())
        guard deliveryStatus == noErr else {
            throw CarbonHotkeyOSTestError.deliveryFailed(deliveryStatus)
        }
    }
}

private final class CarbonHotkeyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [HotkeyEvent] = []

    var events: [HotkeyEvent] {
        lock.withLock { storedEvents }
    }

    func append(_ event: HotkeyEvent) {
        lock.withLock { storedEvents.append(event) }
    }
}

private enum CarbonHotkeyOSTestError: Error {
    case createEventFailed(OSStatus)
    case setParameterFailed(OSStatus)
    case deliveryFailed(OSStatus)
}
