import Foundation

/// Errors that can occur during dictation.
public enum DictationError: Error, Sendable, Equatable {

    /// The audio data is empty or too short to process.
    case emptyAudio

    /// The server rejected the request due to invalid credentials.
    case authenticationFailed

    /// The server rate-limited the request (HTTP 429).
    case rateLimited

    /// The server returned an error with the given status code and message.
    case requestFailed(statusCode: Int, message: String)

    /// The server response could not be parsed.
    case invalidResponse

    /// A network error occurred.
    case networkError(String)
}
