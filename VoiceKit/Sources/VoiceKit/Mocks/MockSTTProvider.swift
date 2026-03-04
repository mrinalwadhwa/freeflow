import Foundation

/// A mock STT provider that returns configurable text for testing.
///
/// Track call counts and recorded arguments to verify pipeline behavior
/// without making real network calls.
public final class MockSTTProvider: STTProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var _transcribeCallCount: Int = 0
    private var _receivedAudioData: [Data] = []

    /// The text returned by `transcribe(audio:)`.
    /// Change this between calls to simulate different transcription results.
    public var stubbedText: String

    /// An optional error to throw instead of returning text.
    /// When non-nil, `transcribe(audio:)` throws this error.
    public var stubbedError: (any Error)?

    /// Number of times `transcribe(audio:)` has been called.
    public var transcribeCallCount: Int {
        lock.withLock { _transcribeCallCount }
    }

    /// Audio data received in each call, in order.
    public var receivedAudioData: [Data] {
        lock.withLock { _receivedAudioData }
    }

    /// The most recent audio data received, or nil if never called.
    public var lastReceivedAudio: Data? {
        lock.withLock { _receivedAudioData.last }
    }

    public init(stubbedText: String = "Mock transcription") {
        self.stubbedText = stubbedText
    }

    public func transcribe(audio: Data) async throws -> String {
        lock.withLock {
            _transcribeCallCount += 1
            _receivedAudioData.append(audio)
        }

        if let error = stubbedError {
            throw error
        }

        return stubbedText
    }

    /// Remove all recorded calls.
    public func reset() {
        lock.withLock {
            _transcribeCallCount = 0
            _receivedAudioData.removeAll()
        }
    }
}
