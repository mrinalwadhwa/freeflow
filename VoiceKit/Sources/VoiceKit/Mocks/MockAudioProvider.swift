import Foundation

/// A mock AudioProviding implementation that returns stub data.
///
/// Used in tests to exercise the pipeline without real audio capture hardware.
public final class MockAudioProvider: AudioProviding, @unchecked Sendable {

    private let lock = NSLock()

    private var _isRecording = false
    private var _startCallCount = 0
    private var _stopCallCount = 0

    /// The audio buffer returned by `stopRecording()`. Defaults to a short
    /// non-silent buffer so the silence gate does not reject it.
    public var stubbedBuffer: AudioBuffer

    /// Number of times `startRecording()` has been called.
    public var startCallCount: Int {
        lock.withLock { _startCallCount }
    }

    /// Number of times `stopRecording()` has been called.
    public var stopCallCount: Int {
        lock.withLock { _stopCallCount }
    }

    public init(stubbedBuffer: AudioBuffer? = nil) {
        self.stubbedBuffer =
            stubbedBuffer
            ?? Self.makeNonSilentBuffer()
    }

    /// Build a 1-second WAV buffer with audible samples.
    ///
    /// Alternates ±3000 samples so the RMS (~0.09) is well above the
    /// default silence threshold (0.005). Uses WAVEncoder to produce a
    /// valid WAV file with a proper RIFF header.
    private static func makeNonSilentBuffer() -> AudioBuffer {
        let sampleRate = 16000
        let channels = 1
        let bitsPerSample = 16
        let sampleCount = sampleRate  // 1 second

        var pcmData = Data(capacity: sampleCount * (bitsPerSample / 8))
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }

        let wavData = WAVEncoder.encode(
            pcmData: pcmData,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        let duration = WAVEncoder.duration(
            byteCount: pcmData.count,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )

        return AudioBuffer(
            data: wavData,
            duration: duration,
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }

    public var isRecording: Bool {
        lock.withLock { _isRecording }
    }

    public func startRecording() async throws {
        lock.withLock {
            _isRecording = true
            _startCallCount += 1
        }
    }

    public var audioLevelStream: AsyncStream<Float>? { nil }

    public func stopRecording() async throws -> AudioBuffer {
        let buffer = lock.withLock { () -> AudioBuffer in
            _isRecording = false
            _stopCallCount += 1
            return stubbedBuffer
        }
        return buffer
    }
}
