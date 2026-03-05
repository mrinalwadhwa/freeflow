import Foundation

/// A mock AudioProviding implementation that returns stub data.
///
/// Used in tests to exercise the pipeline without real audio capture hardware.
public final class MockAudioProvider: AudioProviding, @unchecked Sendable {

    private let lock = NSLock()

    private var _isRecording = false
    private var _startCallCount = 0
    private var _stopCallCount = 0

    /// The audio buffer returned by `stopRecording()`. Defaults to a short silent buffer.
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
            ?? AudioBuffer(
                data: Data(repeating: 0, count: 32000),  // 1 second of silence at 16kHz 16-bit mono
                duration: 1.0
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
