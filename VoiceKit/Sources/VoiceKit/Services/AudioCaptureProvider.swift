import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Capture audio from the default input device via AVAudioEngine.
///
/// Records audio and converts it to 16kHz, mono, 16-bit PCM. On stop,
/// the accumulated samples are WAV-encoded into an `AudioBuffer`.
///
/// The engine is created once on the first `startRecording()` call and
/// kept running across sessions. Start/stop only installs and removes
/// the input tap, avoiding the 0.5-1.2s engine setup cost on each
/// press. The engine is torn down on audio device changes
/// (`AVAudioEngineConfigurationChange`) and rebuilt on the next
/// recording. Call `shutdown()` on app termination.
///
/// Requires microphone permission before calling `startRecording()`.
public final class AudioCaptureProvider: AudioProviding, @unchecked Sendable {

    /// Target audio format for dictation: 16kHz, mono, 16-bit integer PCM.
    static let targetSampleRate: Double = 16000
    static let targetChannels: AVAudioChannelCount = 1
    static let targetBitsPerSample = 16

    private let lock = NSLock()
    private var _isRecording = false

    private var _peakRMS: Float = 0
    private var pcmChunks: [Data] = []

    #if canImport(AVFoundation)
        /// Persistent engine, created on first recording and reused.
        private var engine: AVAudioEngine?
        private var converter: AVAudioConverter?
        /// The tap format negotiated with the hardware on engine creation.
        private var tapFormat: AVAudioFormat?
        /// Observer token for audio device configuration changes.
        private var configChangeObserver: NSObjectProtocol?
    #endif

    // MARK: - PCM audio stream

    private var _pcmAudioStream: AsyncStream<Data>?
    private var pcmContinuation: AsyncStream<Data>.Continuation?

    public var pcmAudioStream: AsyncStream<Data>? {
        lock.withLock { _pcmAudioStream }
    }

    // MARK: - Audio level stream

    private var _audioLevelStream: AsyncStream<Float>?
    private var levelContinuation: AsyncStream<Float>.Continuation?

    public var audioLevelStream: AsyncStream<Float>? {
        lock.withLock { _audioLevelStream }
    }

    /// The highest RMS level observed during the current (or most recent)
    /// recording session. Reset to 0 on each `startRecording()`. The
    /// pipeline reads this after `stopRecording()` to detect silent
    /// presses before sending audio to the server.
    public var peakRMS: Float {
        lock.withLock { _peakRMS }
    }

    public init() {}

    deinit {
        #if canImport(AVFoundation)
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            engine?.stop()
        #endif
    }

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
                _peakRMS = 0

                // Set up the PCM audio stream before starting capture.
                let (pcmStream, pcmCont) = AsyncStream<Data>.makeStream()
                self._pcmAudioStream = pcmStream
                self.pcmContinuation = pcmCont

                // Set up the audio level stream before starting capture.
                let (stream, continuation) = AsyncStream<Float>.makeStream()
                self._audioLevelStream = stream
                self.levelContinuation = continuation

                // Create or reuse the persistent engine.
                let engine = try ensureEngine()

                // Reuse or create the converter. The converter depends on
                // the tap format which is stable as long as the engine and
                // hardware device are unchanged.
                let converter = try ensureConverter()

                let bufferSize: AVAudioFrameCount = 4096
                engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) {
                    [weak self] buffer, _ in
                    self?.emitAudioLevel(buffer)
                    self?.processAudioBuffer(buffer, converter: converter)
                }

                _isRecording = true
            }
        #else
            throw AudioCaptureError.noInputDevice
        #endif
    }

    public func stopRecording() async throws -> AudioBuffer {
        #if canImport(AVFoundation)
            // Grab the engine reference and mark not-recording under the
            // lock, but do NOT call removeTap inside the lock. removeTap
            // synchronously waits for any in-flight tap callback to
            // finish, and the tap callback acquires this same lock to
            // append PCM chunks — calling removeTap while holding the
            // lock deadlocks when a callback is in progress.
            let engineToStop: AVAudioEngine? = lock.withLock {
                guard _isRecording else { return nil }
                _isRecording = false
                return engine
            }

            guard let engineToStop else {
                return .empty
            }

            // Remove the tap outside the lock. This blocks until any
            // in-flight tap callback completes, which is safe because
            // we are not holding the lock. After this returns, no more
            // callbacks will fire.
            engineToStop.inputNode.removeTap(onBus: 0)

            // Collect accumulated data and tear down streams under the
            // lock. No tap callbacks can race here because removeTap
            // has already drained them.
            let pcmData: Data = lock.withLock {
                pcmContinuation?.finish()
                pcmContinuation = nil
                _pcmAudioStream = nil
                levelContinuation?.finish()
                levelContinuation = nil
                _audioLevelStream = nil

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

    /// Tear down the audio engine. Call on app termination.
    public func shutdown() {
        #if canImport(AVFoundation)
            lock.withLock {
                tearDownEngineLocked()
            }
        #endif
    }

    // MARK: - Persistent engine management

    #if canImport(AVFoundation)
        /// Return the existing engine or create a new one. Must be called
        /// while `lock` is held. Starts the engine and registers for
        /// configuration change notifications on first creation.
        private func ensureEngine() throws -> AVAudioEngine {
            if let engine {
                // Engine exists but may have been stopped by a config change
                // notification that only invalidated the converter. Make sure
                // it is running.
                if !engine.isRunning {
                    engine.prepare()
                    try engine.start()
                }
                return engine
            }

            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            let hardwareFormat = inputNode.outputFormat(forBus: 0)
            guard hardwareFormat.sampleRate > 0 else {
                throw AudioCaptureError.noInputDevice
            }

            // Use a float intermediate for the tap, then convert to int16.
            guard
                let tapFmt = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: hardwareFormat.sampleRate,
                    channels: hardwareFormat.channelCount,
                    interleaved: false
                )
            else {
                throw AudioCaptureError.formatError
            }

            engine.prepare()
            try engine.start()

            self.engine = engine
            self.tapFormat = tapFmt
            // Invalidate the converter so it is rebuilt against the new tap format.
            self.converter = nil

            registerConfigChangeObserver()

            return engine
        }

        /// Return the existing converter or create one matching `tapFormat`.
        /// Must be called while `lock` is held and after `ensureEngine()`.
        private func ensureConverter() throws -> AVAudioConverter {
            if let converter {
                return converter
            }

            guard let tapFormat else {
                throw AudioCaptureError.formatError
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

            guard let converter = AVAudioConverter(from: tapFormat, to: targetFormat) else {
                throw AudioCaptureError.formatError
            }
            self.converter = converter
            return converter
        }

        /// Register for `AVAudioEngineConfigurationChange` to handle device
        /// switches (e.g. AirPods connect/disconnect). Tears down the engine
        /// so it is rebuilt with the new hardware format on the next recording.
        private func registerConfigChangeObserver() {
            // Remove any previous observer before registering a new one.
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }

            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Log.debug("[AudioCapture] Engine configuration changed (device switch)")
                self.lock.withLock {
                    self.handleConfigChangeLocked()
                }
            }
        }

        /// Handle an audio configuration change while `lock` is held.
        /// If recording, stop the current session's streams so consumers
        /// see them end. The engine is torn down; `ensureEngine()` will
        /// rebuild it on the next `startRecording()`.
        private func handleConfigChangeLocked() {
            if _isRecording {
                // Remove tap before tearing down.
                engine?.inputNode.removeTap(onBus: 0)
                pcmContinuation?.finish()
                pcmContinuation = nil
                _pcmAudioStream = nil
                levelContinuation?.finish()
                levelContinuation = nil
                _audioLevelStream = nil
                _isRecording = false
            }
            tearDownEngineLocked()
        }

        /// Stop the engine and clear cached state. Must be called while
        /// `lock` is held.
        private func tearDownEngineLocked() {
            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            engine?.stop()
            engine = nil
            converter = nil
            tapFormat = nil
        }
    #endif

    // MARK: - Audio level metering

    #if canImport(AVFoundation)
        /// Compute RMS level from a float32 PCM buffer, update peak tracking,
        /// and emit the scaled level to the stream.
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
                // Track the raw (unscaled) peak for silence detection.
                if rms > _peakRMS {
                    _peakRMS = rms
                }
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
                pcmContinuation?.yield(data)
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
