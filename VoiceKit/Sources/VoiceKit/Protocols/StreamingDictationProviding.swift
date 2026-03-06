import Foundation

/// Stream audio for real-time transcription and receive polished text.
///
/// Unlike `DictationProviding`, which sends a complete WAV file after
/// recording ends, a streaming provider accepts audio chunks during
/// recording. The server transcribes audio in real time so the result
/// is available almost immediately after the last chunk is sent.
///
/// Lifecycle:
///   1. `startStreaming(context:language:)` — open a connection.
///   2. `sendAudio(_:)` — call repeatedly with PCM chunks.
///   3. `finishStreaming()` — signal end of audio, receive result.
///   4. `cancelStreaming()` — abort without waiting for a result.
///
/// Implementations must be safe to call from any isolation context.
/// A single streaming session is active at a time; calling
/// `startStreaming` while a session is open is a programming error.
public protocol StreamingDictationProviding: Sendable {

    /// Open a streaming transcription session.
    ///
    /// - Parameters:
    ///   - context: Application context at the time of dictation.
    ///   - language: Optional ISO-639-1 language hint (e.g. "en").
    /// - Throws: If the connection cannot be established.
    func startStreaming(context: AppContext, language: String?) async throws

    /// Send a chunk of raw PCM audio to the server.
    ///
    /// Audio must be 16-bit signed little-endian PCM at 16 kHz, mono.
    /// The server handles any resampling required by the transcription
    /// model. Chunks can be any size; smaller chunks reduce latency.
    ///
    /// - Parameter pcmData: Raw PCM bytes (no WAV header).
    /// - Throws: If the session is not open or the send fails.
    func sendAudio(_ pcmData: Data) async throws

    /// Signal the end of audio and receive the final transcript.
    ///
    /// Block until the server finishes transcription and cleanup,
    /// then return the polished text ready for injection.
    ///
    /// - Returns: The cleaned-up transcript, or an empty string if
    ///   no speech was detected.
    /// - Throws: On network errors or if the session is not open.
    func finishStreaming() async throws -> String

    /// Abort the current streaming session without waiting for results.
    ///
    /// Safe to call if no session is open (no-op in that case).
    func cancelStreaming() async
}
