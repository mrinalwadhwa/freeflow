import Foundation

/// Whether dictation uses cloud APIs or on-device processing.
///
/// Cloud mode sends audio to OpenAI for transcription and polishing.
/// Local mode uses Apple SpeechAnalyzer and Foundation Models, keeping
/// all data on-device. Local mode requires macOS 26+ with Apple
/// Intelligence enabled.
///
/// Persisted in UserDefaults. Defaults to cloud.
public enum DictationMode: String, CaseIterable, Sendable {
    case cloud
    case local

    /// Human-readable name for display in settings.
    public var displayName: String {
        switch self {
        case .cloud: return "Cloud"
        case .local: return "On-Device"
        }
    }

    /// Whether on-device mode is available on this system.
    ///
    /// Requires macOS 26+ for SpeechAnalyzer and Foundation Models.
    public static var isLocalAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }
}
