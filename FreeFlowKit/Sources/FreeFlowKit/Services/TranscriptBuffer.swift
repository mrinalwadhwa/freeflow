import Foundation

/// Hold the most recent transcript for no-target recovery and re-paste.
///
/// The pipeline writes to the buffer after dictation completes. Consumers:
/// - No-target recovery: inject the buffered transcript via a special shortcut.
/// - Menu bar "Paste last transcript" item.
///
/// Does not touch the system clipboard. Text injection uses the same
/// `TextInjecting` pathway as normal injection.
public actor TranscriptBuffer {

    private var _lastTranscript: String?
    private var _timestamp: Date?

    public init() {}

    /// The most recent transcript, or nil if none has been stored.
    public var lastTranscript: String? {
        _lastTranscript
    }

    /// When the most recent transcript was stored, or nil if empty.
    public var timestamp: Date? {
        _timestamp
    }

    /// Whether a transcript is available to paste.
    public var hasTranscript: Bool {
        _lastTranscript != nil
    }

    /// Store a new transcript, replacing any previous value.
    public func store(_ transcript: String) {
        _lastTranscript = transcript
        _timestamp = Date()
    }

    /// Retrieve and clear the stored transcript.
    ///
    /// Returns the transcript if one was stored, or nil if the buffer is empty.
    /// The buffer is cleared after retrieval so the same transcript is not
    /// injected twice by accident.
    public func consume() -> String? {
        let transcript = _lastTranscript
        _lastTranscript = nil
        _timestamp = nil
        return transcript
    }

    /// Clear the buffer without retrieving the transcript.
    public func clear() {
        _lastTranscript = nil
        _timestamp = nil
    }
}
