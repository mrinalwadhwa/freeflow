import Foundation

/// Errors that can occur during speech-to-text transcription.
public enum STTError: Error, Sendable, Equatable {

    /// The audio data is empty or too short to transcribe.
    case emptyAudio

    /// The server rejected the request due to invalid credentials.
    case authenticationFailed

    /// The server returned an error with the given status code and message.
    case transcriptionFailed(statusCode: Int, message: String)

    /// The server response could not be parsed.
    case invalidResponse

    /// A network error occurred.
    case networkError(String)
}
