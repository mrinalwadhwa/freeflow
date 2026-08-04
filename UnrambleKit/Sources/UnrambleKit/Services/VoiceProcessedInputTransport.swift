import Foundation

#if canImport(AVFoundation) && canImport(AudioToolbox) && canImport(CoreAudio)
    import AVFoundation
    import AudioToolbox
    import CoreAudio

    /// Captures one concrete Core Audio input through the system voice
    /// processing unit, which subtracts device playback from the
    /// microphone signal and suppresses stationary noise.
    ///
    /// The echo canceller references audio the system renders to the
    /// output device, so speech synthesis and cue sounds played by
    /// separate engines are removed from the captured signal without
    /// routing them through this unit. The unit's own output bus stays
    /// active rendering silence: voice processing is built around a
    /// live duplex graph, and an idle output bus keeps the canceller
    /// engaged. Automatic gain control stays off so captured levels
    /// keep the same meaning as the direct transport's; other-audio
    /// ducking is pinned to its minimum so narration keeps its volume
    /// while the microphone listens.
    final class VoiceProcessedInputTransport: AUHALInputTransporting,
        @unchecked Sendable
    {
        let format: AVAudioFormat
        let deviceID: AudioObjectID

        private let audioUnit: AudioUnit
        private let callbackState: CallbackState
        private let farEndHub: FarEndPlaybackHub?
        private let farEndChannel: FarEndPlaybackChannel?
        private let renderState: FarEndRenderState
        private let stateLock = NSLock()
        private var isStarted = false

        init(
            deviceID: AudioObjectID,
            farEndHub: FarEndPlaybackHub? = nil
        ) throws {
            self.deviceID = deviceID
            self.farEndHub = farEndHub

            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description)
            else {
                throw Self.error("find voice processing component", status: -1)
            }

            var candidate: AudioUnit?
            try Self.check(
                AudioComponentInstanceNew(component, &candidate),
                operation: "create voice processing instance")
            guard let unit = candidate else {
                throw Self.error("create voice processing instance", status: -1)
            }

            do {
                var enabled: UInt32 = 1
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Input,
                        1,
                        &enabled,
                        UInt32(MemoryLayout<UInt32>.size)),
                    operation: "enable voice processing input")
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Output,
                        0,
                        &enabled,
                        UInt32(MemoryLayout<UInt32>.size)),
                    operation: "enable voice processing output")

                // Pin the input bus to the chosen device; the output bus
                // follows the system default so silence renders wherever
                // playback already goes.
                var mutableDeviceID = deviceID
                let inputBusRoute = AudioUnitSetProperty(
                    unit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    1,
                    &mutableDeviceID,
                    UInt32(MemoryLayout<AudioObjectID>.size))
                if inputBusRoute != noErr {
                    try Self.check(
                        AudioUnitSetProperty(
                            unit,
                            kAudioOutputUnitProperty_CurrentDevice,
                            kAudioUnitScope_Global,
                            0,
                            &mutableDeviceID,
                            UInt32(MemoryLayout<AudioObjectID>.size)),
                        operation: "route voice processing to device \(deviceID)")
                }

                var agcOff: UInt32 = 0
                let agcStatus = AudioUnitSetProperty(
                    unit,
                    kAUVoiceIOProperty_VoiceProcessingEnableAGC,
                    kAudioUnitScope_Global,
                    0,
                    &agcOff,
                    UInt32(MemoryLayout<UInt32>.size))
                if agcStatus != noErr {
                    Log.debug(
                        "[VoiceProcessedCapture] AGC disable failed "
                            + "(\(agcStatus)); continuing with default")
                }

                var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
                    mEnableAdvancedDucking: false,
                    mDuckingLevel: .min)
                let duckingStatus = AudioUnitSetProperty(
                    unit,
                    kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
                    kAudioUnitScope_Global,
                    0,
                    &ducking,
                    UInt32(
                        MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>
                            .size))
                if duckingStatus != noErr {
                    Log.debug(
                        "[VoiceProcessedCapture] ducking configuration failed "
                            + "(\(duckingStatus)); continuing with default")
                }

                var unitFormat = AudioStreamBasicDescription()
                var formatSize = UInt32(
                    MemoryLayout<AudioStreamBasicDescription>.size)
                try Self.check(
                    AudioUnitGetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Input,
                        1,
                        &unitFormat,
                        &formatSize),
                    operation: "read voice processing input format")
                guard unitFormat.mSampleRate > 0,
                    unitFormat.mChannelsPerFrame > 0
                else {
                    throw Self.error(
                        "validate voice processing input format", status: -1)
                }

                Log.debug(
                    "[VoiceProcessedCapture] unit input format "
                        + "rate=\(unitFormat.mSampleRate) "
                        + "channels=\(unitFormat.mChannelsPerFrame)")

                // The processed signal is a single voice channel, so the
                // client format is always mono: multi-channel input devices
                // (aggregates, interfaces) stay on the device side of the
                // unit, and mono streams need no channel layout to become
                // an AVAudioFormat. Walk from the unit's rate toward its
                // native voice rate until one sticks.
                let candidates: [Double] = [
                    unitFormat.mSampleRate,
                    24_000,
                    48_000,
                ]
                var acceptedFormat: AVAudioFormat?
                for sampleRate in candidates {
                    var clientFormat = Self.floatFormat(
                        sampleRate: sampleRate,
                        channels: 1)
                    let status = AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Output,
                        1,
                        &clientFormat,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
                    guard status == noErr else {
                        Log.debug(
                            "[VoiceProcessedCapture] client format "
                                + "rate=\(sampleRate) refused (\(status))")
                        continue
                    }
                    guard
                        let format = AVAudioFormat(
                            streamDescription: &clientFormat)
                    else {
                        Log.debug(
                            "[VoiceProcessedCapture] client format "
                                + "rate=\(sampleRate) unrepresentable")
                        continue
                    }
                    acceptedFormat = format
                    break
                }
                if acceptedFormat == nil {
                    var defaultFormat = AudioStreamBasicDescription()
                    var defaultSize = UInt32(
                        MemoryLayout<AudioStreamBasicDescription>.size)
                    let status = AudioUnitGetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Output,
                        1,
                        &defaultFormat,
                        &defaultSize)
                    if status == noErr,
                        defaultFormat.mSampleRate > 0,
                        defaultFormat.mChannelsPerFrame > 0,
                        let format = AVAudioFormat(
                            streamDescription: &defaultFormat)
                    {
                        Log.debug(
                            "[VoiceProcessedCapture] using unit default "
                                + "client format rate=\(format.sampleRate) "
                                + "channels=\(format.channelCount) "
                                + "common=\(format.commonFormat.rawValue) "
                                + "interleaved=\(format.isInterleaved)")
                        acceptedFormat = format
                    }
                }
                guard let format = acceptedFormat else {
                    throw Self.error(
                        "set voice processing client format", status: -1)
                }
                // The unit initializes only when both buses agree on a
                // rate; mirror the client format onto the silent output
                // bus so the graph is coherent.
                var outputFormat = Self.floatFormat(
                    sampleRate: format.sampleRate,
                    channels: 1)
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Input,
                        0,
                        &outputFormat,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                    operation: "set voice processing output format")

                self.format = format
                callbackState = try CallbackState(
                    audioUnit: unit,
                    format: format)
                audioUnit = unit

                // The output bus doubles as the canceller's far-end
                // reference: while a hub is present, speech playback
                // routes through this ring and is cancelled from the
                // microphone as the unit's own audio, not merely
                // suppressed as other apps' audio.
                if farEndHub != nil {
                    let ring = FarEndAudioRing(
                        capacity: Int(format.sampleRate * 4))
                    let channel = FarEndPlaybackChannel(
                        ring: ring,
                        sampleRate: format.sampleRate)
                    farEndChannel = channel
                    renderState = FarEndRenderState(ring: ring)
                } else {
                    farEndChannel = nil
                    renderState = FarEndRenderState(ring: nil)
                }

                var inputCallback = AURenderCallbackStruct(
                    inputProc: voiceProcessedProductionInputCallback,
                    inputProcRefCon: Unmanaged.passUnretained(callbackState)
                        .toOpaque())
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_SetInputCallback,
                        kAudioUnitScope_Global,
                        0,
                        &inputCallback,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                    operation: "install voice processing input callback")

                var outputCallback = AURenderCallbackStruct(
                    inputProc: voiceProcessedFarEndRenderCallback,
                    inputProcRefCon: Unmanaged.passUnretained(renderState)
                        .toOpaque())
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_SetRenderCallback,
                        kAudioUnitScope_Input,
                        0,
                        &outputCallback,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                    operation: "install voice processing output render")

                try Self.check(
                    AudioUnitInitialize(unit),
                    operation: "initialize voice processing unit")
            } catch {
                AudioComponentInstanceDispose(unit)
                throw error
            }
            Log.debug(
                "[VoiceProcessedCapture] Created device=\(deviceID) "
                    + "sampleRate=\(format.sampleRate) "
                    + "channels=\(format.channelCount)")
        }

        deinit {
            stop()
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
        }

        func start(
            handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) throws {
            try stateLock.withLock {
                guard !isStarted else {
                    callbackState.setHandler(handler)
                    return
                }
                callbackState.setHandler(handler)
                do {
                    try Self.check(
                        AudioOutputUnitStart(audioUnit),
                        operation: "start voice processing unit")
                    isStarted = true
                } catch {
                    callbackState.setHandler(nil)
                    throw error
                }
            }
            if let farEndHub, let farEndChannel {
                farEndHub.activate(farEndChannel)
            }
        }

        func stop() {
            if let farEndHub, let farEndChannel {
                farEndHub.deactivate(farEndChannel)
            }
            stateLock.withLock {
                guard isStarted else {
                    callbackState.setHandler(nil)
                    return
                }
                AudioOutputUnitStop(audioUnit)
                isStarted = false
                callbackState.setHandler(nil)
            }
        }

        private static func floatFormat(
            sampleRate: Double,
            channels: UInt32
        ) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat
                    | kAudioFormatFlagIsPacked
                    | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: channels * UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: channels * UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0)
        }

        private static func check(
            _ status: OSStatus,
            operation: String
        ) throws {
            guard status == noErr else { throw error(operation, status: status) }
        }

        private static func error(
            _ operation: String,
            status: OSStatus
        ) -> NSError {
            NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: "\(operation) failed (\(status))"
                ])
        }

        fileprivate final class CallbackState: @unchecked Sendable {
            typealias Handler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

            let audioUnit: AudioUnit
            let sampleRate: Double
            let buffer: AVAudioPCMBuffer
            private let handlerLock = NSLock()
            private var handler: Handler?

            init(audioUnit: AudioUnit, format: AVAudioFormat) throws {
                self.audioUnit = audioUnit
                sampleRate = format.sampleRate
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        frameCapacity: 16_384)
                else {
                    throw VoiceProcessedInputTransport.error(
                        "allocate voice processing callback buffer",
                        status: -1)
                }
                self.buffer = buffer
            }

            func setHandler(_ handler: Handler?) {
                handlerLock.withLock { self.handler = handler }
            }

            func render(
                actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                timestamp: UnsafePointer<AudioTimeStamp>,
                frameCount: UInt32
            ) -> OSStatus {
                guard frameCount <= buffer.frameCapacity else {
                    return kAudio_ParamError
                }
                buffer.frameLength = frameCount
                let status = AudioUnitRender(
                    audioUnit,
                    actionFlags,
                    timestamp,
                    1,
                    frameCount,
                    buffer.mutableAudioBufferList)
                guard status == noErr else { return status }

                guard let handler = handlerLock.withLock({ handler }) else {
                    return noErr
                }
                var audioTimestamp = timestamp.pointee
                let time = AVAudioTime(
                    audioTimeStamp: &audioTimestamp,
                    sampleRate: sampleRate)
                handler(buffer, time)
                return noErr
            }
        }
    }

    private let voiceProcessedProductionInputCallback: AURenderCallback = {
        refCon,
        actionFlags,
        timestamp,
        _,
        frameCount,
        _ in
        let state = Unmanaged<VoiceProcessedInputTransport.CallbackState>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        return state.render(
            actionFlags: actionFlags,
            timestamp: timestamp,
            frameCount: frameCount)
    }

    private let voiceProcessedFarEndRenderCallback: AURenderCallback = {
        refCon,
        actionFlags,
        _,
        _,
        _,
        ioData in
        let state = Unmanaged<FarEndRenderState>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        return state.fill(ioData: ioData, actionFlags: actionFlags)
    }
#endif
