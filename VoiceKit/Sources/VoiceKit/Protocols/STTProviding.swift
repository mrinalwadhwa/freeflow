import Foundation

/// Transcribe audio data to text.
///
/// Implementations send audio (typically a complete WAV file) to a
/// speech-to-text service and return the transcribed text.
public protocol STTProviding: Sendable {

    /// Transcribe the given audio data to text.
    ///
    /// - Parameter audio: A complete WAV file (RIFF header + PCM data).
    /// - Returns: The transcribed text.
    /// - Throws: If transcription fails due to network, auth, or service errors.
    func transcribe(audio: Data) async throws -> String
}
