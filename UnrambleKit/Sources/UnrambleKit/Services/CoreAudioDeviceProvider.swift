import Foundation

#if canImport(CoreAudio)
    import CoreAudio
#endif

#if canImport(IOKit)
    import IOKit
#endif

/// Enumerate and select audio input devices using Core Audio.
///
/// Uses `AudioObjectGetPropertyData` to list physical and virtual input
/// devices, read their names, and detect the system default. Device
/// selection stores the chosen device ID; `AudioCaptureProvider` reads
/// it before creating or reconfiguring its `AVAudioEngine`.
///
/// Listens for hardware device list changes (connect/disconnect) and
/// default device changes so `availableDevices()` always reflects the
/// current state.
/// Reads and writes the persisted input-selection UID. Injectable so
/// tests never touch the user's real defaults.
public struct InputSelectionStore: Sendable {
    public let readUID: @Sendable () -> String?
    public let writeUID: @Sendable (String?) -> Void

    public init(
        readUID: @escaping @Sendable () -> String?,
        writeUID: @escaping @Sendable (String?) -> Void
    ) {
        self.readUID = readUID
        self.writeUID = writeUID
    }

    /// The production store, backed by app settings.
    public static var settings: InputSelectionStore {
        InputSelectionStore(
            readUID: { Settings.shared.selectedInputDeviceUID },
            writeUID: { Settings.shared.selectedInputDeviceUID = $0 })
    }

    /// An in-memory store for tests.
    public static func ephemeral() -> InputSelectionStore {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var uid: String?
        }
        let box = Box()
        return InputSelectionStore(
            readUID: { box.lock.withLock { box.uid } },
            writeUID: { newValue in box.lock.withLock { box.uid = newValue } })
    }
}

public final class CoreAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {

    private let lock = NSLock()

    /// Persists the explicit selection's device UID across relaunches
    /// and Bluetooth renegotiation.
    private let selectionStore: InputSelectionStore

    /// Explicitly selected device ID, or nil to use the system default.
    private var _selectedDeviceID: UInt32?

    /// Weak reference to the audio capture provider. When a device
    /// list or default-device change is detected, the provider is
    /// notified so it can mark its engine for rebuild. AVAudioEngine
    /// does not emit configuration-change notifications when stopped,
    /// so without this, device changes between recording sessions
    /// leave the engine with stale CoreAudio state.
    private weak var _audioCaptureProvider: (any AudioCaptureRebuildSink)?

    /// Listeners registered with Core Audio for device changes.
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Serial queue that coalesces a burst of device-change notifications.
    private let deviceChangeQueue = DispatchQueue(
        label: "computer.unramble.coreaudio-device-change")
    /// Pending debounced rebuild check, cancelled and rescheduled per event.
    private var pendingDeviceChangeCheck: DispatchWorkItem?
    /// How long device-change notifications must settle before acting. A churn
    /// storm (Continuity, virtual devices, Bluetooth flapping) fires many
    /// notifications in a burst; coalescing them into one decision avoids the
    /// repeated engine rebuilds that burst otherwise triggers.
    private static let deviceChangeDebounceSeconds = 0.3
    /// AirPods route changes have blocked output-engine playback for 5.65s in
    /// live traces. Keep cues off briefly after input-device churn so feedback
    /// playback cannot delay or disrupt microphone callbacks.
    static let soundFeedbackCooldownSeconds: TimeInterval = 10
    private let transitionGate = AudioInputDeviceTransitionGate()
    private var lastDeviceChangeUptime: TimeInterval?

    public init(selectionStore: InputSelectionStore = .settings) {
        self.selectionStore = selectionStore
        #if canImport(CoreAudio)
            registerListeners()
        #endif
    }

    /// Set the audio capture provider to notify on device changes.
    ///
    /// Call once during setup, after both providers are created.
    /// The provider is held weakly to avoid retain cycles.
    public func setAudioCaptureProvider(_ provider: any AudioCaptureRebuildSink) {
        lock.withLock { _audioCaptureProvider = provider }
    }

    deinit {
        #if canImport(CoreAudio)
            unregisterListeners()
        #endif
    }

    // MARK: - AudioDeviceProviding

    public func availableDevices() async -> [AudioDevice] {
        #if canImport(CoreAudio)
            return listInputDevices()
        #else
            return []
        #endif
    }

    public func currentDevice() async -> AudioDevice? {
        #if canImport(CoreAudio)
            let devices = listInputDevices()
            let selectedID = resolveSelection(in: devices)

            if let selectedID {
                // Return the selected device if it still exists.
                if let device = devices.first(where: { $0.id == selectedID }) {
                    return device
                }
                // Selected device was disconnected — fall through to default.
            }

            // Return the device auto-detect will actually pin for capture, so
            // the HUD never claims an unstable Bluetooth default is active
            // while capture is safely using the built-in microphone.
            guard
                let captureID = Self.preferredCaptureDeviceID(
                    devices: devices, selectedDeviceID: nil)
            else { return nil }
            return devices.first(where: { $0.id == captureID })
        #else
            return nil
        #endif
    }

    public func selectDevice(id: UInt32) async throws {
        #if canImport(CoreAudio)
            let devices = listInputDevices()
            guard devices.contains(where: { $0.id == id }) else {
                throw CoreAudioDeviceError.deviceNotFound(id)
            }
            let captureProvider = lock.withLock { () -> (any AudioCaptureRebuildSink)? in
                _selectedDeviceID = id
                return _audioCaptureProvider
            }
            // The numeric ID dies with the next Bluetooth renegotiation
            // or relaunch; the UID is what the selection re-attaches to.
            selectionStore.writeUID(getDeviceUID(deviceID: id))
            noteDeviceTransition()
            captureProvider?.markNeedsRebuild()
            Log.debug("[CoreAudioDeviceProvider] Selected device id=\(id)")
        #else
            throw CoreAudioDeviceError.coreAudioUnavailable
        #endif
    }

    /// The device ID that should be used for the next recording session.
    ///
    /// Returns the explicitly selected device, or nil to use the system
    /// default. `AudioCaptureProvider` reads this before creating its
    /// engine to configure the correct input device.
    public var selectedDeviceID: UInt32? {
        lock.withLock { _selectedDeviceID }
    }

    /// Pin one concrete device for the capture generation. Auto-detect avoids
    /// a Bluetooth default when a built-in microphone is available: AirPods
    /// can advertise themselves as default while sitting unworn outside their
    /// case, then deliver discontinuous capture timestamps. Users who
    /// explicitly choose AirPods still get that device.
    public var captureDeviceID: UInt32? {
        #if canImport(CoreAudio)
            let devices = listInputDevices()
            let selected = resolveSelection(in: devices)
            let preferred = Self.preferredCaptureDeviceID(
                devices: devices, selectedDeviceID: selected)
            if selected == nil,
                let systemDefault = devices.first(where: \.isDefault),
                systemDefault.transportType == .bluetooth,
                preferred != systemDefault.id
            {
                let preferredDescription = preferred?.description ?? "none"
                Log.debug(
                    "[CoreAudioDeviceProvider] Auto-detect bypassing Bluetooth default \(systemDefault.id) for stable device \(preferredDescription)")
            }
            return preferred
        #else
            return selectedDeviceID
        #endif
    }

    /// Collapse Bluetooth zombie twins. A Bluetooth profile
    /// transition briefly leaves a dead duplicate of a headset
    /// enumerating beside the live device under the same name; a menu
    /// that lists both invites selecting the corpse. Keep the system
    /// default, else the newest object — CoreAudio object IDs grow as
    /// devices are created, so the highest ID is the survivor. Wired
    /// transports never collapse: identically named USB or display
    /// devices are legitimately distinct hardware.
    static func collapsingBluetoothTwins(
        _ devices: [AudioDevice]
    ) -> [AudioDevice] {
        var bestTwin: [String: AudioDevice] = [:]
        for device in devices where device.transportType == .bluetooth {
            if let current = bestTwin[device.name] {
                let keepCurrent =
                    current.isDefault
                    || (!device.isDefault && current.id > device.id)
                if !keepCurrent { bestTwin[device.name] = device }
            } else {
                bestTwin[device.name] = device
            }
        }
        return devices.filter { device in
            guard device.transportType == .bluetooth else { return true }
            return bestTwin[device.name]?.id == device.id
        }
    }

    static func preferredCaptureDeviceID(
        devices: [AudioDevice], selectedDeviceID: UInt32?
    ) -> UInt32? {
        if let selectedDeviceID,
            devices.contains(where: { $0.id == selectedDeviceID })
        {
            return selectedDeviceID
        }
        guard let systemDefault = devices.first(where: \.isDefault)
            ?? devices.first
        else { return nil }
        if systemDefault.transportType == .bluetooth,
            let builtIn = devices.first(where: {
                $0.transportType == .builtIn
            })
        {
            return builtIn.id
        }
        return systemDefault.id
    }

    public func waitUntilInputDeviceSettled() async throws {
        try await transitionGate.waitUntilSettled()
    }

    public var isSoundFeedbackSafe: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let age = lock.withLock {
            lastDeviceChangeUptime.map { now - $0 }
        }
        return AudioCaptureSoundFeedbackPolicy.allowsSound(
            requested: true,
            secondsSinceDeviceChange: age,
            cooldown: Self.soundFeedbackCooldownSeconds)
    }

    /// Whether the user is in auto-detect mode (no explicit selection).
    public var isAutoDetect: Bool {
        lock.withLock { _selectedDeviceID == nil }
    }

    /// Clear the explicit device selection, reverting to auto-detect.
    public func clearSelection() {
        let captureProvider = lock.withLock { () -> (any AudioCaptureRebuildSink)? in
            _selectedDeviceID = nil
            return _audioCaptureProvider
        }
        selectionStore.writeUID(nil)
        noteDeviceTransition()
        captureProvider?.markNeedsRebuild()
        Log.debug("[CoreAudioDeviceProvider] Cleared selection, using auto-detect")
    }

    public func clearUnavailableCaptureSelection() {
        lock.withLock { _selectedDeviceID = nil }
        // Capture failed on this device; re-attaching to it by UID
        // would loop straight back into the failure.
        selectionStore.writeUID(nil)
        Log.debug(
            "[CoreAudioDeviceProvider] Cleared unavailable capture device, using system default"
        )
    }

    /// Whether the MacBook lid is closed (clamshell mode).
    ///
    /// When true and the built-in mic is selected, audio quality
    /// will be poor because the mic is behind the closed lid.
    public var isClamshellClosed: Bool {
        #if canImport(IOKit)
            var iterator: io_iterator_t = 0
            let result = IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("IOPMrootDomain"),
                &iterator)
            guard result == KERN_SUCCESS else { return false }
            defer { IOObjectRelease(iterator) }

            let service = IOIteratorNext(iterator)
            guard service != 0 else { return false }
            defer { IOObjectRelease(service) }

            guard let prop = IORegistryEntryCreateCFProperty(
                service,
                "AppleClamshellState" as CFString,
                kCFAllocatorDefault,
                0)?.takeRetainedValue()
            else { return false }

            return (prop as? Bool) ?? false
        #else
            return false
        #endif
    }

    /// Return the mic proximity for a device ID.
    ///
    /// If `deviceID` is nil (system default), looks up the current
    /// default input device. Returns `.nearField` if the device
    /// cannot be found.
    public func micProximityForDevice(_ deviceID: UInt32?) -> MicProximity {
        #if canImport(CoreAudio)
            let id: AudioObjectID
            if let deviceID {
                id = deviceID
            } else if let defaultID = getDefaultInputDeviceID() {
                id = defaultID
            } else {
                return .nearField
            }
            switch getTransportType(deviceID: id) {
            case .builtIn, .usb, .other:
                return .farField
            case .bluetooth:
                return .nearField
            }
        #else
            return .nearField
        #endif
    }

    /// Return the device name for a device ID.
    ///
    /// If `deviceID` is nil (system default), looks up the current
    /// default input device. Returns `nil` if the device cannot be
    /// found.
    public func deviceNameForDevice(_ deviceID: UInt32?) -> String? {
        #if canImport(CoreAudio)
            let id: AudioObjectID
            if let deviceID {
                id = deviceID
            } else if let defaultID = getDefaultInputDeviceID() {
                id = defaultID
            } else {
                return nil
            }
            return getDeviceName(deviceID: id)
        #else
            return nil
        #endif
    }

    private func noteDeviceTransition() {
        lock.withLock {
            lastDeviceChangeUptime = ProcessInfo.processInfo.systemUptime
        }
        transitionGate.begin(
            settleAfter: Self.deviceChangeDebounceSeconds)
    }

    // MARK: - Core Audio Enumeration

    #if canImport(CoreAudio)

        /// List audio input devices, filtering out virtual and
        /// aggregate devices that aren't real microphones.
        private func listInputDevices() -> [AudioDevice] {
            let allDeviceIDs = getAllAudioDeviceIDs()
            let defaultInputID = getDefaultInputDeviceID()

            var inputDevices: [AudioDevice] = []

            for deviceID in allDeviceIDs {
                guard hasInputStreams(deviceID: deviceID) else { continue }
                guard isDeviceAlive(deviceID: deviceID) else { continue }
                guard let name = getDeviceName(deviceID: deviceID) else { continue }

                let transport = getTransportType(deviceID: deviceID)

                Log.debug(
                    "[CoreAudioDeviceProvider] Input device: \"\(name)\" "
                    + "id=\(deviceID) transport=\(transport)"
                    + (deviceID == defaultInputID ? " (default)" : "")
                )

                // Skip known virtual and aggregate devices.
                // Allow transport=other for real hardware like
                // iPhone Continuity Microphone.
                if isVirtualDevice(name: name) { continue }

                let device = AudioDevice(
                    id: deviceID,
                    name: name,
                    isDefault: deviceID == defaultInputID,
                    transportType: transport
                )
                inputDevices.append(device)
            }

            return Self.collapsingBluetoothTwins(inputDevices)
        }

        /// Resolve the explicit selection against the current device
        /// list. A stale numeric ID re-attaches through the persisted
        /// device UID — the identity that survives Bluetooth
        /// renegotiation and relaunches. Auto-detect stays nil.
        private func resolveSelection(in devices: [AudioDevice]) -> UInt32? {
            let numeric = lock.withLock { _selectedDeviceID }
            if let numeric, devices.contains(where: { $0.id == numeric }) {
                return numeric
            }
            guard let storedUID = selectionStore.readUID()
            else {
                if numeric != nil {
                    lock.withLock { _selectedDeviceID = nil }
                }
                return nil
            }
            guard
                let match = devices.first(where: {
                    getDeviceUID(deviceID: $0.id) == storedUID
                })
            else {
                if numeric != nil {
                    lock.withLock { _selectedDeviceID = nil }
                }
                return nil
            }
            lock.withLock { _selectedDeviceID = match.id }
            Log.debug(
                "[CoreAudioDeviceProvider] Selection re-attached to "
                    + "\"\(match.name)\" id=\(match.id)")
            return match.id
        }

        /// Get all audio device IDs on the system.
        private func getAllAudioDeviceIDs() -> [AudioObjectID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize: UInt32 = 0
            let sizeStatus = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            )
            guard sizeStatus == noErr, dataSize > 0 else { return [] }

            let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
            var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)

            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceIDs
            )
            guard status == noErr else { return [] }

            return deviceIDs
        }

        /// Get the system default input device ID.
        private func getDefaultInputDeviceID() -> AudioObjectID? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceID: AudioObjectID = kAudioObjectUnknown
            var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            )

            guard status == noErr, deviceID != kAudioObjectUnknown else {
                return nil
            }
            return deviceID
        }

        /// Check whether a device has input streams (i.e. is a microphone).
        private func hasInputStreams(deviceID: AudioObjectID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var dataSize: UInt32 = 0
            let status = AudioObjectGetPropertyDataSize(
                deviceID,
                &address,
                0,
                nil,
                &dataSize
            )

            // A device with input streams has dataSize > 0.
            return status == noErr && dataSize > 0
        }

        /// Map the Core Audio transport type constant to our enum.
        private func getTransportType(deviceID: AudioObjectID) -> AudioDevice.TransportType {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var transportType: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &transportType
            )

            guard status == noErr else { return .other }

            switch transportType {
            case kAudioDeviceTransportTypeBuiltIn:
                return .builtIn
            case kAudioDeviceTransportTypeBluetooth,
                kAudioDeviceTransportTypeBluetoothLE:
                return .bluetooth
            case kAudioDeviceTransportTypeUSB:
                return .usb
            default:
                return .other
            }
        }

        /// Check if a device is a known virtual/aggregate device that
        /// should be hidden from the mic menu.
        private func isVirtualDevice(name: String) -> Bool {
            let lower = name.lowercased()
            return lower.contains("aggregate")
                || lower.contains("zoomaudiodevice")
                || lower.contains("screencastaudio")
                || lower.contains("blackhole")
                || lower.contains("loopback")
                || lower.contains("soundflower")
        }

        /// Get the human-readable name of a device.
        /// Whether the device object is still alive. A Bluetooth
        /// zombie can keep enumerating with streams after its link
        /// died; a missing property is treated as alive.
        private func isDeviceAlive(deviceID: AudioObjectID) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var alive: UInt32 = 1
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &dataSize, &alive)
            guard status == noErr else { return true }
            return alive != 0
        }

        /// The device's stable CoreAudio UID, or nil when unreadable.
        private func getDeviceUID(deviceID: AudioObjectID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var dataSize = UInt32(MemoryLayout<CFString>.size)
            let status = AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &dataSize, &uid)
            guard status == noErr else { return nil }
            let value = uid as String
            return value.isEmpty ? nil : value
        }

        private func getDeviceName(deviceID: AudioObjectID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var name: CFString = "" as CFString
            var dataSize = UInt32(MemoryLayout<CFString>.size)

            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &name
            )

            guard status == noErr else { return nil }
            return name as String
        }

        // MARK: - Device Change Listeners

        /// Register listeners for device list changes and default device changes.
        private func registerListeners() {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                Log.debug("[CoreAudioDeviceProvider] Device list changed")
                self.scheduleDeviceChangeCheck()
            }

            let devicesStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                nil,
                devicesBlock
            )
            if devicesStatus != noErr {
                Log.debug("[CoreAudioDeviceProvider] Failed to register device list listener: \(devicesStatus)")
            }
            deviceListListenerBlock = devicesBlock

            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                Log.debug("[CoreAudioDeviceProvider] Default input device changed")
                self.scheduleDeviceChangeCheck()
            }

            let defaultStatus = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                nil,
                defaultBlock
            )
            if defaultStatus != noErr {
                Log.debug("[CoreAudioDeviceProvider] Failed to register default device listener: \(defaultStatus)")
            }
            defaultDeviceListenerBlock = defaultBlock
        }

        /// Coalesce device-change notifications: cancel any pending check and
        /// schedule a fresh one, so a burst of notifications settles into a
        /// single rebuild decision instead of one rebuild per notification.
        private func scheduleDeviceChangeCheck() {
            noteDeviceTransition()
            deviceChangeQueue.async { [weak self] in
                guard let self else { return }
                self.pendingDeviceChangeCheck?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.handleDeviceChangeSettled()
                }
                self.pendingDeviceChangeCheck = work
                self.deviceChangeQueue.asyncAfter(
                    deadline: .now() + Self.deviceChangeDebounceSeconds,
                    execute: work)
            }
        }

        /// Act on a settled device change. A selection whose numeric ID
        /// died re-attaches through its persisted UID — the same
        /// headset back under a fresh ID keeps its chosen status. Only
        /// a selection with no surviving device reverts to auto-detect,
        /// and the UID stays stored so the device is re-adopted when it
        /// returns. Runs once per settled burst.
        private func handleDeviceChangeSettled() {
            let (before, captureProvider):
                (UInt32?, (any AudioCaptureRebuildSink)?) = lock.withLock {
                    (self._selectedDeviceID, self._audioCaptureProvider)
                }
            let devices = listInputDevices()
            let resolved = resolveSelection(in: devices)
            if let before {
                if resolved == before {
                    // Selected device still present — skip rebuild.
                } else {
                    if resolved == nil {
                        Log.debug(
                            "[CoreAudioDeviceProvider] Selected device \(before) disconnected, reverting to default"
                        )
                    }
                    captureProvider?.markNeedsRebuild()
                }
            } else {
                // Auto-detect, or a stored selection whose device just
                // returned — rebuild to pick up the change.
                captureProvider?.markNeedsRebuild()
            }
        }

        /// Remove all registered Core Audio listeners.
        private func unregisterListeners() {
            if let block = deviceListListenerBlock {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDevices,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    nil,
                    block
                )
                deviceListListenerBlock = nil
            }

            if let block = defaultDeviceListenerBlock {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    nil,
                    block
                )
                defaultDeviceListenerBlock = nil
            }
        }

    #endif
}

/// Errors thrown by `CoreAudioDeviceProvider`.
public enum CoreAudioDeviceError: Error, Sendable {
    case deviceNotFound(UInt32)
    case coreAudioUnavailable
}
