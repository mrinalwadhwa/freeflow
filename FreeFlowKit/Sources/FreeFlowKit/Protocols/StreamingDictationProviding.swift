import Foundation

/// Stream audio for real-time transcription and receive polished text.
///
/// Unlike `DictationProviding`, which sends a complete WAV file after
/// recording ends, a streaming provider accepts audio chunks during
/// recording. The server transcribes audio in real time so the result
/// is available almost immediately after the last chunk is sent.
///
/// Lifecycle:
///   1. Optionally `setChunkHandler(_:)` to receive incremental
///      chunks as audio crosses the chunking strategy's boundaries.
///   2. `startStreaming(context:language:)` — open a connection.
///   3. `sendAudio(_:)` — call repeatedly with PCM chunks.
///   4. `finishStreaming()` — signal end of audio, receive the
///      final chunk's polished text.
///   5. `cancelStreaming()` — abort without waiting for a result.
///
/// When a chunk handler is set, sessions that cross the strategy's
/// chunk boundary commit audio incrementally. Each intermediate chunk
/// is delivered to the handler as soon as it is transcribed and
/// polished; the final chunk is returned from `finishStreaming` as
/// usual. A session that never crosses the first boundary behaves
/// the same as one with no handler: one commit at `finishStreaming`.
///
/// Implementations must be safe to call from any isolation context.
/// A single streaming session is active at a time; calling
/// `startStreaming` while a session is open is a programming error.
public protocol StreamingDictationProviding: Sendable {

    /// Duration (in seconds) of audio sent since the last successful
    /// commit. The pipeline uses this to extract the tail audio for
    /// batch recovery when the streaming session fails.
    var uncommittedAudioDuration: TimeInterval { get }

    /// Register a handler to receive intermediate chunks for the next
    /// session. Call before `startStreaming`. Passing `nil` clears the
    /// handler so the next session behaves like a single-commit run.
    ///
    /// The handler is invoked from an unspecified executor once per
    /// committed chunk, with the chunk's polished text. It is not
    /// called for the final chunk — that one is returned from
    /// `finishStreaming`.
    func setChunkHandler(_ handler: (@Sendable (String) async -> Void)?)

    /// Open a streaming transcription session.
    ///
    /// - Parameters:
    ///   - context: Application context at the time of dictation.
    ///   - language: Optional ISO-639-1 language hint (e.g. "en").
    ///   - micProximity: Whether the mic is near-field (headset) or
    ///     far-field (built-in laptop mic). The server uses this to
    ///     configure noise reduction on the transcription backend.
    /// - Throws: If the connection cannot be established.
    func startStreaming(context: AppContext, language: String?, micProximity: MicProximity)
        async throws

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

/// Default implementations so conforming types only need to implement
/// the methods they support. `setChunkHandler` is a no-op by default,
/// so providers that do not support rolling chunks are transparent to
/// callers that try to set a handler.
extension StreamingDictationProviding {

    public var uncommittedAudioDuration: TimeInterval { 0 }

    public func setChunkHandler(_ handler: (@Sendable (String) async -> Void)?) {}
}
