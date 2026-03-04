import Foundation

/// Read service connection settings from environment variables.
///
/// Centralizes URL and API key resolution so that all service clients
/// (STT, future LLM, TTS) use the same configuration source.
public enum ServiceConfig {

    /// Base URL of the VoiceService Autonomy app.
    ///
    /// Reads `VOICE_SERVICE_URL` from the environment.
    /// Falls back to `http://localhost:8000` for local development.
    public static var baseURL: String {
        ProcessInfo.processInfo.environment["VOICE_SERVICE_URL"]
            ?? "http://localhost:8000"
    }

    /// API key for authenticating with the VoiceService.
    ///
    /// Reads `VOICE_API_KEY` from the environment.
    /// Falls back to an empty string (requests will fail with 401).
    public static var apiKey: String {
        ProcessInfo.processInfo.environment["VOICE_API_KEY"] ?? ""
    }
}
