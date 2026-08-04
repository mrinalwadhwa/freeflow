import Foundation

#if canImport(AVFoundation) && canImport(CoreAudio)
    import AVFoundation
    import CoreAudio

    /// Keep the most recently built capture transport alive across
    /// sessions so a start does not rebuild it.
    ///
    /// Building the voice processing unit takes seconds, so paying that
    /// cost on every dictation start would put the whole delay between
    /// the press and the first captured word. A transport is reused
    /// only while it still matches the requested device and transport
    /// kind and its device is still alive; otherwise it is dropped and
    /// rebuilt.
    final class CaptureTransportCache: @unchecked Sendable {

        private struct Entry {
            let deviceID: AudioObjectID
            let voiceProcessing: Bool
            let transport: any AUHALInputTransporting
        }

        private let lock = NSLock()
        private let isDeviceAlive: @Sendable (AudioObjectID) -> Bool
        private var entry: Entry?

        init(
            isDeviceAlive: @escaping @Sendable (AudioObjectID) -> Bool = {
                CaptureTransportCache.deviceIsAlive($0)
            }
        ) {
            self.isDeviceAlive = isDeviceAlive
        }

        func transport(
            deviceID: AudioObjectID,
            voiceProcessing: Bool,
            build: (AudioObjectID, Bool) throws -> any AUHALInputTransporting
        ) throws -> any AUHALInputTransporting {
            let cached = lock.withLock { () -> (any AUHALInputTransporting)? in
                guard let entry,
                    entry.deviceID == deviceID,
                    entry.voiceProcessing == voiceProcessing
                else { return nil }
                return entry.transport
            }
            if let cached, isDeviceAlive(deviceID) {
                Log.debug(
                    "[AUHALCapture] Reusing prepared transport "
                        + "device=\(deviceID)")
                return cached
            }
            let built = try build(deviceID, voiceProcessing)
            lock.withLock {
                entry = Entry(
                    deviceID: deviceID,
                    voiceProcessing: voiceProcessing,
                    transport: built)
            }
            return built
        }

        private static func deviceIsAlive(_ deviceID: AudioObjectID) -> Bool {
            var alive: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsAlive,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, &alive)
            return status == noErr && alive != 0
        }
    }
#endif
