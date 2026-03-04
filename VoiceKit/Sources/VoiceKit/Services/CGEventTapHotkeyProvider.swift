import Foundation

#if canImport(ApplicationServices)
    import ApplicationServices
#endif

#if canImport(Carbon)
    import Carbon.HIToolbox
#endif

/// Register a global hotkey listener for Right Option via CGEventTap.
///
/// Creates a passive CGEventTap that monitors `.flagsChanged` events
/// system-wide. When the Right Option key is pressed or released, the
/// registered callback fires with `.pressed` or `.released`.
///
/// Requires the app to be trusted for accessibility (`AXIsProcessTrusted`).
public final class CGEventTapHotkeyProvider: HotkeyProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var callback: (@Sendable (HotkeyEvent) -> Void)?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var _isRightOptionDown = false

    /// The CGEvent flags mask for Right Option (Right Alternate).
    /// NX_DEVICERALTKEYMASK = 0x00000040 in the device-dependent flags region.
    private static let rightOptionDeviceFlag: UInt64 = 0x0000_0040

    public init() {}

    deinit {
        unregister()
    }

    // MARK: - HotkeyProviding

    public func register(callback: @escaping @Sendable (HotkeyEvent) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        // Remove any existing tap before creating a new one.
        tearDownTap()

        self.callback = callback
        self._isRightOptionDown = false

        #if canImport(ApplicationServices)
            // Verify accessibility permission before attempting to create the tap.
            guard AXIsProcessTrusted() else {
                throw HotkeyRegistrationError.accessibilityNotGranted
            }

            let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

            // Use an Unmanaged pointer to self so the C callback can reach us.
            let selfPointer = Unmanaged.passUnretained(self).toOpaque()

            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    options: .listenOnly,
                    eventsOfInterest: eventMask,
                    callback: cgEventCallback,
                    userInfo: selfPointer
                )
            else {
                throw HotkeyRegistrationError.tapCreationFailed
            }

            self.eventTap = tap

            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            self.runLoopSource = source

            // Run the event tap on a dedicated background thread so it doesn't
            // block the main thread or depend on the caller's run loop.
            let thread = Thread { [weak self] in
                guard let self, let source else { return }
                let rl = CFRunLoopGetCurrent()
                self.lock.lock()
                self.tapRunLoop = rl
                self.lock.unlock()
                CFRunLoopAddSource(rl, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                CFRunLoopRun()
            }
            thread.name = "com.buildtrust.voice.hotkey"
            thread.qualityOfService = .userInteractive
            self.tapThread = thread
            thread.start()
        #else
            throw HotkeyRegistrationError.tapCreationFailed
        #endif
    }

    public func unregister() {
        lock.lock()
        defer { lock.unlock() }
        tearDownTap()
    }

    // MARK: - Internal

    /// Re-enable the event tap if the system disabled it. Called from the
    /// CGEventTap C callback when a `.tapDisabledByTimeout` or
    /// `.tapDisabledByUserInput` event arrives.
    fileprivate func reEnableTap() {
        lock.lock()
        let tap = eventTap
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Handle a flags-changed event. Called from the CGEventTap C callback.
    fileprivate func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags.rawValue

        // Check the device-dependent flags for Right Option specifically.
        let rightOptionPressed = (flags & Self.rightOptionDeviceFlag) != 0

        lock.lock()
        let wasDown = _isRightOptionDown
        let cb = callback
        lock.unlock()

        if rightOptionPressed && !wasDown {
            lock.lock()
            _isRightOptionDown = true
            lock.unlock()
            cb?(.pressed)
        } else if !rightOptionPressed && wasDown {
            lock.lock()
            _isRightOptionDown = false
            lock.unlock()
            cb?(.released)
        }
    }

    /// Tear down the event tap and its run loop. Must be called with the lock held.
    private func tearDownTap() {
        callback = nil
        _isRightOptionDown = false

        #if canImport(ApplicationServices)
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
        #endif

        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }

        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }

        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
    }
}

// MARK: - CGEventTap C callback

#if canImport(ApplicationServices)
    /// The C-compatible callback invoked by the CGEventTap.
    ///
    /// Extracts the `CGEventTapHotkeyProvider` instance from `userInfo` and
    /// forwards `.flagsChanged` events to `handleFlagsChanged(_:)`.
    private func cgEventCallback(
        proxy _: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        userInfo: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let provider = Unmanaged<CGEventTapHotkeyProvider>
            .fromOpaque(userInfo)
            .takeUnretainedValue()

        switch type {
        case .flagsChanged:
            provider.handleFlagsChanged(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap if the system disables it.
            provider.reEnableTap()
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }
#endif

// MARK: - Errors

/// Errors that can occur when registering the global hotkey.
public enum HotkeyRegistrationError: Error, Sendable, CustomStringConvertible {
    /// The app is not trusted for accessibility. The user must grant access
    /// in System Settings > Privacy & Security > Accessibility.
    case accessibilityNotGranted
    /// Failed to create the CGEventTap. This can happen if another process
    /// has exclusive control or the system is in a restricted state.
    case tapCreationFailed

    public var description: String {
        switch self {
        case .accessibilityNotGranted:
            return
                "Accessibility permission not granted. Open System Settings > Privacy & Security > Accessibility."
        case .tapCreationFailed:
            return "Failed to create global event tap"
        }
    }
}
