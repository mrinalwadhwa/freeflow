import Foundation

/// Decide when to commit the current chunk during a streaming dictation
/// session.
///
/// A `ChunkingStrategy` is consulted by the provider each time a new
/// block of PCM audio arrives. Returning `true` causes the provider to
/// send `input_audio_buffer.commit` to the OpenAI Realtime API, which
/// finalizes the current user turn and produces a transcription. The
/// next audio chunk starts a new turn.
///
/// A session that ends before the first commit boundary produces one
/// chunk at `finishStreaming`. A session that crosses the boundary
/// commits incrementally so the transcript is delivered to the caller
/// chunk by chunk and no single commit contains more audio than the
/// strategy's ceiling.
///
/// Strategies are pure: they take only the current timing and speech
/// state, and return a decision. This makes them trivial to unit test
/// without running a live session.
public protocol ChunkingStrategy: Sendable {

    /// Return `true` if the provider should commit the audio buffered
    /// since the last commit right now.
    ///
    /// - Parameters:
    ///   - sinceLastCommitSeconds: Seconds elapsed since the last
    ///     successful commit, or since the session started if no chunk
    ///     has been committed yet.
    ///   - isSpeaking: Whether the most recent audio chunk contained
    ///     speech above the silence threshold.
    /// - Returns: `true` if a commit should fire now, `false` to
    ///   continue buffering.
    func shouldCommitNow(
        sinceLastCommitSeconds: TimeInterval,
        isSpeaking: Bool
    ) -> Bool
}

/// Commit every `maxChunkSeconds`, or earlier when the speaker has
/// paused after accumulating at least `minSilenceCommitSeconds` of
/// audio.
///
/// The defaults — 5 min maximum and 3 min minimum-before-silence —
/// keep chunks rare so normal dictations produce a single commit.
/// Chunking only fires as a safety net for very long sessions that
/// would otherwise hit the Realtime API's undocumented session-length
/// ceiling (~10–20 min).
public struct TimeAndSilenceChunkingStrategy: ChunkingStrategy {

    /// Hard upper bound on chunk length. Commit fires once this many
    /// seconds have elapsed since the last commit, regardless of speech
    /// state.
    public let maxChunkSeconds: TimeInterval

    /// Minimum chunk length before a silence-triggered early commit is
    /// allowed. Prevents flushing on every mid-sentence breath during
    /// the first second or two of a chunk.
    public let minSilenceCommitSeconds: TimeInterval

    public init(
        maxChunkSeconds: TimeInterval = 300,
        minSilenceCommitSeconds: TimeInterval = 180
    ) {
        self.maxChunkSeconds = maxChunkSeconds
        self.minSilenceCommitSeconds = minSilenceCommitSeconds
    }

    public func shouldCommitNow(
        sinceLastCommitSeconds: TimeInterval,
        isSpeaking: Bool
    ) -> Bool {
        if sinceLastCommitSeconds >= maxChunkSeconds {
            return true
        }
        if sinceLastCommitSeconds >= minSilenceCommitSeconds && !isSpeaking {
            return true
        }
        return false
    }
}
