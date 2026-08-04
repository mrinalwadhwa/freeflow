import Foundation

#if canImport(CoreAudio)
    import CoreAudio

    /// Shadow the HAL's own voice activity detection on a capture
    /// device, logging its transitions without gating anything.
    ///
    /// The level-based detector cannot distinguish a quiet voice from
    /// narration residual, so barging is closed to voices under the
    /// emphatic bar. Apple's VAD judges spectral shape, not level; if
    /// its transitions line up with real speech in live logs — firing
    /// on quiet voices, staying silent under narration residual — it
    /// becomes the barge evidence. The probe only observes: enable
    /// the detection property, listen for state changes, and log
    /// "[HALVAD]" lines against the detector's "[TurnRun]" timeline.
    /// Devices without the property degrade to a single soft log.
    final class VoiceActivityShadowProbe {

        private let deviceID: AudioObjectID
        private let queue = DispatchQueue(
            label: "computer.unramble.halvad-probe")
        private let lock = NSLock()
        private var listening = false
        private var listenerBlock: AudioObjectPropertyListenerBlock?

        private static var stateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionState,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        private static var enableAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVoiceActivityDetectionEnable,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        init(deviceID: AudioObjectID) {
            self.deviceID = deviceID
        }

        deinit {
            stop()
        }

        func start() {
            // Enabling the detection property made the device gate its
            // input stream during silence, which fails capture
            // integrity at timestampCoverage and loses the turn — so
            // the probe runs only when a round is deliberately opted
            // into it.
            guard Settings.shared.halVadProbeEnabled else { return }
            lock.withLock {
                guard !listening else { return }
                var enable: UInt32 = 1
                let enableStatus = AudioObjectSetPropertyData(
                    deviceID,
                    &Self.enableAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<UInt32>.size),
                    &enable)
                guard enableStatus == noErr else {
                    Log.debug(
                        "[HALVAD] unavailable on device=\(deviceID) "
                            + "(\(enableStatus))")
                    return
                }
                let deviceID = deviceID
                let block: AudioObjectPropertyListenerBlock = { _, _ in
                    var active: UInt32 = 0
                    var size = UInt32(MemoryLayout<UInt32>.size)
                    let status = AudioObjectGetPropertyData(
                        deviceID,
                        &Self.stateAddress,
                        0,
                        nil,
                        &size,
                        &active)
                    guard status == noErr else { return }
                    Log.debug(
                        "[HALVAD] active=\(active) "
                            + "at \(CFAbsoluteTimeGetCurrent())")
                }
                let listenStatus = AudioObjectAddPropertyListenerBlock(
                    deviceID, &Self.stateAddress, queue, block)
                guard listenStatus == noErr else {
                    Log.debug(
                        "[HALVAD] listener failed on device=\(deviceID) "
                            + "(\(listenStatus))")
                    return
                }
                listenerBlock = block
                listening = true
                Log.debug("[HALVAD] shadow probe on device=\(deviceID)")
            }
        }

        func stop() {
            lock.withLock {
                guard listening, let block = listenerBlock else { return }
                AudioObjectRemovePropertyListenerBlock(
                    deviceID, &Self.stateAddress, queue, block)
                var disable: UInt32 = 0
                AudioObjectSetPropertyData(
                    deviceID,
                    &Self.enableAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<UInt32>.size),
                    &disable)
                listenerBlock = nil
                listening = false
            }
        }
    }
#endif
