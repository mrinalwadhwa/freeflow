import Foundation

/// Speaks text aloud through the system audio output.
///
/// The v1 implementation wraps the system synthesizer; a local neural TTS
/// engine can replace it behind this protocol without touching callers.
public protocol SpeechSynthesizing: Sendable {

    /// Speak the given text, returning when speech finishes or is stopped.
    func speak(_ text: String) async

    /// Stop speech immediately. A pending `speak` call returns promptly.
    func stopSpeaking()
}
