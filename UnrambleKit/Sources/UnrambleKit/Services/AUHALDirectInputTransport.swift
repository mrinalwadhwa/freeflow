import Foundation

#if canImport(AVFoundation) && canImport(AudioToolbox) && canImport(CoreAudio)
    import AVFoundation
    import AudioToolbox
    import CoreAudio

    protocol AUHALInputTransporting: AnyObject, Sendable {
        var format: AVAudioFormat { get }
        var deviceID: AudioObjectID { get }
        func start(
            handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) throws
        func stop()
    }

    final class AUHALDirectInputTransport: AUHALInputTransporting,
        @unchecked Sendable
    {
        let format: AVAudioFormat
        let deviceID: AudioObjectID

        private let audioUnit: AudioUnit
        private let callbackState: CallbackState
        private let stateLock = NSLock()
        private var isStarted = false

        init(deviceID: AudioObjectID) throws {
            self.deviceID = deviceID

            var description = AudioComponentDescription(
                componentType: kAudioUnitType_Output,
                componentSubType: kAudioUnitSubType_HALOutput,
                componentManufacturer: kAudioUnitManufacturer_Apple,
                componentFlags: 0,
                componentFlagsMask: 0)
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw Self.error("find AUHAL component", status: -1)
            }

            var candidate: AudioUnit?
            try Self.check(
                AudioComponentInstanceNew(component, &candidate),
                operation: "create AUHAL instance")
            guard let unit = candidate else {
                throw Self.error("create AUHAL instance", status: -1)
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
                    operation: "enable AUHAL input")

                var disabled: UInt32 = 0
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_EnableIO,
                        kAudioUnitScope_Output,
                        0,
                        &disabled,
                        UInt32(MemoryLayout<UInt32>.size)),
                    operation: "disable AUHAL output")

                var mutableDeviceID = deviceID
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_CurrentDevice,
                        kAudioUnitScope_Global,
                        0,
                        &mutableDeviceID,
                        UInt32(MemoryLayout<AudioObjectID>.size)),
                    operation: "route AUHAL to device \(deviceID)")

                var deviceFormat = AudioStreamBasicDescription()
                var formatSize = UInt32(
                    MemoryLayout<AudioStreamBasicDescription>.size)
                try Self.check(
                    AudioUnitGetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Input,
                        1,
                        &deviceFormat,
                        &formatSize),
                    operation: "read AUHAL device format")
                guard deviceFormat.mSampleRate > 0,
                    deviceFormat.mChannelsPerFrame > 0
                else {
                    throw Self.error("validate AUHAL device format", status: -1)
                }

                let channels = deviceFormat.mChannelsPerFrame
                var clientFormat = AudioStreamBasicDescription(
                    mSampleRate: deviceFormat.mSampleRate,
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
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioUnitProperty_StreamFormat,
                        kAudioUnitScope_Output,
                        1,
                        &clientFormat,
                        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                    operation: "set AUHAL client format")

                guard let format = AVAudioFormat(streamDescription: &clientFormat)
                else {
                    throw Self.error("create AUHAL AVAudioFormat", status: -1)
                }
                self.format = format
                callbackState = try CallbackState(
                    audioUnit: unit,
                    format: format)
                audioUnit = unit

                var callback = AURenderCallbackStruct(
                    inputProc: auhalProductionInputCallback,
                    inputProcRefCon: Unmanaged.passUnretained(callbackState)
                        .toOpaque())
                try Self.check(
                    AudioUnitSetProperty(
                        unit,
                        kAudioOutputUnitProperty_SetInputCallback,
                        kAudioUnitScope_Global,
                        0,
                        &callback,
                        UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                    operation: "install AUHAL callback")
                try Self.check(
                    AudioUnitInitialize(unit),
                    operation: "initialize AUHAL")
            } catch {
                AudioComponentInstanceDispose(unit)
                throw error
            }
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
                        operation: "start AUHAL")
                    isStarted = true
                } catch {
                    callbackState.setHandler(nil)
                    throw error
                }
            }
        }

        func stop() {
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
                    throw AUHALDirectInputTransport.error(
                        "allocate AUHAL callback buffer",
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

    private let auhalProductionInputCallback: AURenderCallback = {
        refCon,
        actionFlags,
        timestamp,
        _,
        frameCount,
        _ in
        let state = Unmanaged<AUHALDirectInputTransport.CallbackState>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        return state.render(
            actionFlags: actionFlags,
            timestamp: timestamp,
            frameCount: frameCount)
    }
#endif
