import Foundation

/// Convert spoken audio into clean written text.
///
/// Implementations send audio data and application context to a
/// server-side dictation service that returns polished text ready
/// for injection.
public protocol DictationProviding: Sendable {

    /// Dictate audio into text using the given application context.
    ///
    /// - Parameters:
    ///   - audio: A complete WAV file (RIFF header + PCM data).
    ///   - context: Application context at the time of dictation (app name,
    ///     window title, existing field content, cursor position, etc.).
    /// - Returns: The final text ready for injection.
    /// - Throws: If the dictation service is unreachable or returns an error.
    func dictate(audio: Data, context: AppContext) async throws -> String
}
