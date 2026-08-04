import Foundation

/// A moment in a dictation session that matters to turn endpointing.
///
/// The streaming providers publish these for the session capturing a
/// conversation call. Audio-derived signals carry the timing — they
/// are real time — while the transcript-derived signal carries the
/// content gate: a pause may only send a turn that transcribed
/// actual speech.
public enum TurnSignal: Sendable, Equatable {

    /// New transcribed text arrived for the session. Local
    /// transcription publishes this per recognition cycle; the cloud
    /// provider — whose realtime transcript arrives only at finish —
    /// publishes it at the start of each audible speech run instead.
    case transcribedSpeech

    /// Speech audio resumed after a published pause, re-arming the
    /// endpoint.
    case audibleSpeech

    /// An audible run's peak cleared several multiples of the noise
    /// floor: the audio carries the level contour of an actual voice,
    /// not a swell of room noise. Sends require this evidence — a
    /// recognizer handed marginal audio invents words.
    case strongSpeech

    /// A strong run whose peak also cleared the level that
    /// echo-cancelled narration residual can reach. Only this
    /// evidence may take the floor from a playing voice; a quieter
    /// voice is indistinguishable from the residual on level alone.
    case emphaticSpeech

    /// Trailing silence in the live audio crossed the send pause.
    case pause
}
