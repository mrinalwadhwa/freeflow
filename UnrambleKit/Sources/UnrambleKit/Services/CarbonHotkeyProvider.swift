import Foundation

#if canImport(Carbon)
    import Carbon.HIToolbox
#endif

/// Registers modifier-plus-key shortcuts with the macOS global hotkey API.
///
/// Carbon global hotkeys receive key combinations without monitoring the
/// system-wide keyboard event stream. Modifier-only shortcuts still require
/// `CGEventTapHotkeyProvider` because Carbon requires a non-modifier key.
public final class CarbonHotkeyProvider: HotkeyProviding, @unchecked Sendable {
    private typealias TimestampedCallback =
        @Sendable (HotkeyEvent, UInt64) -> Void

    private let lock = NSLock()
    private var callback: TimestampedCallback?

    #if canImport(Carbon)
        private var eventHandler: EventHandlerRef?
        private var hotkey: EventHotKeyRef?
        private let registrationID: UInt32

        private static let signature: OSType = 0x554E_524D  // "UNRM"
        private static let registrationIDSource =
            CarbonHotkeyRegistrationIDSource()
    #endif

    public init() {
        #if canImport(Carbon)
            registrationID = Self.registrationIDSource.next()
        #endif
    }

    deinit {
        unregister()
    }

    public func register(
        callback: @escaping @Sendable (HotkeyEvent) -> Void
    ) throws {
        try registerTimestamped { event, _ in callback(event) }
    }

    public func registerTimestamped(
        callback: @escaping @Sendable (HotkeyEvent, UInt64) -> Void
    ) throws {
        try registerTimestamped(
            with: Settings.shared.hotkeySetting,
            callback: callback)
    }

    /// Registers one modifier-plus-key shortcut, replacing any prior shortcut.
    public func register(
        with setting: HotkeySetting,
        callback: @escaping @Sendable (HotkeyEvent) -> Void
    ) throws {
        try registerTimestamped(with: setting) { event, _ in callback(event) }
    }

    public func unregister() {
        #if canImport(Carbon)
            let resources: (EventHotKeyRef?, EventHandlerRef?) = lock.withLock {
                let resources = (hotkey, eventHandler)
                hotkey = nil
                eventHandler = nil
                callback = nil
                return resources
            }

            if let hotkey = resources.0 {
                UnregisterEventHotKey(hotkey)
            }
            if let eventHandler = resources.1 {
                RemoveEventHandler(eventHandler)
            }
        #else
            lock.withLock {
                callback = nil
            }
        #endif
    }

    private func registerTimestamped(
        with setting: HotkeySetting,
        callback: @escaping TimestampedCallback
    ) throws {
        let descriptor = try Self.descriptor(for: setting)
        unregister()

        #if canImport(Carbon)
            var eventTypes = [
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(
                    eventClass: OSType(kEventClassKeyboard),
                    eventKind: UInt32(kEventHotKeyReleased)),
            ]
            var installedHandler: EventHandlerRef?
            let handlerStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotkeyEventHandler,
                eventTypes.count,
                &eventTypes,
                Unmanaged.passUnretained(self).toOpaque(),
                &installedHandler)
            guard handlerStatus == noErr, let installedHandler else {
                throw CarbonHotkeyRegistrationError.installHandlerFailed(
                    handlerStatus)
            }

            let hotkeyID = EventHotKeyID(
                signature: Self.signature,
                id: registrationID)
            var registeredHotkey: EventHotKeyRef?
            let registrationStatus = RegisterEventHotKey(
                descriptor.keyCode,
                descriptor.modifiers,
                hotkeyID,
                GetApplicationEventTarget(),
                OptionBits(0),
                &registeredHotkey)
            guard registrationStatus == noErr, let registeredHotkey else {
                RemoveEventHandler(installedHandler)
                throw CarbonHotkeyRegistrationError.registrationFailed(
                    registrationStatus)
            }

            lock.withLock {
                self.callback = callback
                eventHandler = installedHandler
                hotkey = registeredHotkey
            }
        #else
            _ = descriptor
            _ = callback
            throw CarbonHotkeyRegistrationError.unavailable
        #endif
    }

    fileprivate func handleCarbonEvent(_ event: EventRef) -> OSStatus {
        #if canImport(Carbon)
            var hotkeyID = EventHotKeyID()
            let parameterStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotkeyID)
            guard parameterStatus == noErr else { return parameterStatus }
            guard hotkeyID.signature == Self.signature,
                hotkeyID.id == registrationID
            else { return OSStatus(eventNotHandledErr) }

            let hotkeyEvent: HotkeyEvent
            switch GetEventKind(event) {
            case UInt32(kEventHotKeyPressed):
                hotkeyEvent = .pressed
            case UInt32(kEventHotKeyReleased):
                hotkeyEvent = .released
            default:
                return OSStatus(eventNotHandledErr)
            }

            let callback = lock.withLock { self.callback }
            callback?(
                hotkeyEvent,
                AudioCaptureReleaseFence.currentHostTime())
            return noErr
        #else
            _ = event
            return OSStatus(eventNotHandledErr)
        #endif
    }

    struct Descriptor: Equatable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static func descriptor(
        for setting: HotkeySetting
    ) throws -> Descriptor {
        guard case .modifierPlusKey(let flags, let keyCode, _) = setting else {
            throw CarbonHotkeyRegistrationError.modifierOnlyUnsupported
        }

        var modifiers: UInt32 = 0
        if flags & ShortcutBinding.controlFlag != 0 {
            modifiers |= UInt32(controlKey)
        }
        if flags & ShortcutBinding.optionFlag != 0 {
            modifiers |= UInt32(optionKey)
        }
        if flags & ShortcutBinding.shiftFlag != 0 {
            modifiers |= UInt32(shiftKey)
        }
        if flags & ShortcutBinding.commandFlag != 0 {
            modifiers |= UInt32(cmdKey)
        }
        return Descriptor(keyCode: UInt32(keyCode), modifiers: modifiers)
    }
}

private final class CarbonHotkeyRegistrationIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UInt32 = 0

    func next() -> UInt32 {
        lock.withLock {
            current &+= 1
            return current
        }
    }
}

#if canImport(Carbon)
    private func carbonHotkeyEventHandler(
        nextHandler _: EventHandlerCallRef?,
        event: EventRef?,
        userData: UnsafeMutableRawPointer?
    ) -> OSStatus {
        guard let event, let userData else {
            return OSStatus(eventNotHandledErr)
        }
        let provider = Unmanaged<CarbonHotkeyProvider>
            .fromOpaque(userData)
            .takeUnretainedValue()
        return provider.handleCarbonEvent(event)
    }
#endif

public enum CarbonHotkeyRegistrationError: Error, Sendable,
    CustomStringConvertible
{
    case modifierOnlyUnsupported
    case installHandlerFailed(OSStatus)
    case registrationFailed(OSStatus)
    case unavailable

    public var description: String {
        switch self {
        case .modifierOnlyUnsupported:
            return "Carbon global hotkeys require a non-modifier key"
        case .installHandlerFailed(let status):
            return "Failed to install global hotkey handler (status \(status))"
        case .registrationFailed(let status):
            return "Failed to register global hotkey (status \(status))"
        case .unavailable:
            return "Carbon global hotkeys are unavailable on this platform"
        }
    }
}
