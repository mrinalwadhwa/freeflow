import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Capture audio from the default input device via AVAudioEngine.
///
/// Records audio and converts it to 16kHz, mono, 16-bit PCM. On stop,
/// the accumulated samples are WAV-encoded into an `AudioBuffer`.
///
/// Requires microphone permission before calling `startRecording()`.
public final class AudioCaptureProvider: AudioProviding, @unchecked Sendable {

    /// Target audio format for dictation: 16kHz, mono, 16-bit integer PCM.
    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBitsPerSample = 16

    private let lock = NSLock()
    private var _isRecording = false
    private var pcmChunks: [Data] = []

    #if canImport(AVFoundation)
        private var engine: AVAudioEngine?
        private var converter: AVAudioConverter?
    #endif

    // MARK: - Audio level stream

    private var _audioLevelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    public var audioLevelStream: AsyncStream<Float>? {
        lock.withLock { _audioLevelStream }
    }

    public init() {}

    // MARK: - AudioProviding

    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    public func startRecording() async throws {
        #if canImport(AVFoundation)
            try lock.withLock {
                guard !_isRecording else {
                    throw AudioCaptureError.alreadyRecording
                }

                pcmChunks = []

                // Set up the audio level stream before starting capture.
                let (stream, continuation) = AsyncStream<Float>.makeStream()
                self._audioLevelStream = stream
                self.levelContinuation = continuation

                let engine = AVAudioEngine()
                let inputNode = engine.inputNode

                let hardwareFormat = inputNode.outputFormat(forBus: 0)
                guard hardwareFormat.sampleRate > 0 else {
                    throw AudioCaptureError.noInputDevice
                }

                guard
                    let targetFormat = AVAudioFormat(
                        commonFormat: .pcmFormatInt16,
                        sampleRate: Self.targetSampleRate,
                        channels: Self.targetChannels,
                        interleaved: true
                    )
                else {
                    throw AudioCaptureError.formatError
                }

                // Use a float intermediate for the tap, then convert to int16.
                guard
                    let tapFormat = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: hardwareFormat.sampleRate,
                        channels: hardwareFormat.channelCount,
                        interleaved: false
                    )
                else {
                    throw AudioCaptureError.formatError
                }

                let converter = AVAudioConverter(from: tapFormat, to: targetFormat)
                guard let converter else {
                    throw AudioCaptureError.formatError
                }
                self.converter = converter

                let bufferSize: AVAudioFrameCount = 4096
                inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) {
                    [weak self] buffer, _ in
                    self?.emitAudioLevel(buffer)
                    self?.processAudioBuffer(buffer, converter: converter)
                }

                engine.prepare()
                try engine.start()
                self.engine = engine
                _isRecording = true
            }
        #else
            throw AudioCaptureError.noInputDevice
        #endif
    }

    public func stopRecording() async throws -> AudioBuffer {
        #if canImport(AVFoundation)
            let pcmData: Data = lock.withLock {
                guard _isRecording else { return Data() }

                engine?.inputNode.removeTap(onBus: 0)
                engine?.stop()
                engine = nil
                converter = nil
                levelContinuation?.finish()
                levelContinuation = nil
                _audioLevelStream = nil
                _isRecording = false

                // Concatenate all accumulated PCM chunks.
                let totalSize = pcmChunks.reduce(0) { $0 + $1.count }
                var combined = Data(capacity: totalSize)
                for chunk in pcmChunks {
                    combined.append(chunk)
                }
                pcmChunks = []
                return combined
            }

            if pcmData.isEmpty {
                return .empty
            }

            let duration = WAVEncoder.duration(
                byteCount: pcmData.count,
                sampleRate: Int(Self.targetSampleRate),
                channels: Int(Self.targetChannels),
                bitsPerSample: Self.targetBitsPerSample
            )

            let wavData = WAVEncoder.encode(
                pcmData: pcmData,
                sampleRate: Int(Self.targetSampleRate),
                channels: Int(Self.targetChannels),
                bitsPerSample: Self.targetBitsPerSample
            )

            return AudioBuffer(
                data: wavData,
                duration: duration,
                sampleRate: Int(Self.targetSampleRate),
                channels: Int(Self.targetChannels),
                bitsPerSample: Self.targetBitsPerSample
            )
        #else
            return .empty
        #endif
    }

    // MARK: - Audio level metering

    #if canImport(AVFoundation)
        /// Compute RMS level from a float32 PCM buffer and emit to the stream.
        private func emitAudioLevel(_ buffer: AVAudioPCMBuffer) {
            guard let floatData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            let samples = floatData[0]
            var sumOfSquares: Float = 0
            for i in 0..<frameLength {
                let sample = samples[i]
                sumOfSquares += sample * sample
            }
            let rms = sqrtf(sumOfSquares / Float(frameLength))

            // Raw RMS from speech is typically 0.002-0.02. Scale up
            // aggressively and apply a sqrt curve so quiet speech still
            // moves the bars while loud speech doesn't just pin at 1.0.
            let scaled = min(sqrtf(rms * 25.0), 1.0)

            lock.withLock {
                levelContinuation?.yield(scaled)
            }
        }
    #endif

    // MARK: - Internal

    #if canImport(AVFoundation)
        private func processAudioBuffer(
            _ buffer: AVAudioPCMBuffer,
            converter: AVAudioConverter
        ) {
            // Convert the tap buffer to the target format (16kHz mono int16).
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * Self.targetSampleRate
                    / buffer.format.sampleRate
            )
            guard frameCapacity > 0 else { return }

            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: converter.outputFormat,
                    frameCapacity: frameCapacity + 1
                )
            else { return }

            var error: NSError?
            var inputConsumed = false

            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if let error {
                // Log and skip this chunk rather than crashing.
                debugPrint("Audio conversion error: \(error)")
                return
            }

            guard outputBuffer.frameLength > 0 else { return }

            // Extract raw int16 PCM bytes from the output buffer.
            let byteCount = Int(outputBuffer.frameLength) * (Self.targetBitsPerSample / 8)
            let data: Data
            if let int16Data = outputBuffer.int16ChannelData {
                data = Data(
                    bytes: int16Data[0],
                    count: byteCount
                )
            } else {
                return
            }

            lock.withLock {
                pcmChunks.append(data)
            }
        }
    #endif
}

// MARK: - Errors

/// Errors that can occur during audio capture.
public enum AudioCaptureError: Error, Sendable, CustomStringConvertible {
    /// `startRecording()` was called while already recording.
    case alreadyRecording
    /// No audio input device is available.
    case noInputDevice
    /// Failed to create the required audio format or converter.
    case formatError

    public var description: String {
        switch self {
        case .alreadyRecording:
            return "Audio capture is already in progress"
        case .noInputDevice:
            return "No audio input device available"
        case .formatError:
            return "Failed to configure audio format"
        }
    }
}
