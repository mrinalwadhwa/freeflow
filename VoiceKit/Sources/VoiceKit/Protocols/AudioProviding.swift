import Foundation

/// Provides audio recording capabilities.
///
/// Real implementations use AVAudioEngine to capture from the default input device.
/// A mock implementation returns stub AudioBuffer values for testing.
public protocol AudioProviding: Sendable {

    /// Begin capturing audio from the default input device.
    ///
    /// Throws if the microphone is unavailable or permission has not been granted.
    func startRecording() async throws

    /// Stop capturing and return the recorded audio.
    ///
    /// Returns the audio captured since `startRecording()` was called,
    /// encoded as WAV PCM data in an `AudioBuffer`.
    func stopRecording() async throws -> AudioBuffer

    /// Whether audio is currently being captured.
    var isRecording: Bool { get }
}
