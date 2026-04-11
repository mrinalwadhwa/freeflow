import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device LLM polish client using Apple Foundation Models.
///
/// Calls the on-device ~3B language model via `LanguageModelSession`.
/// The `model` parameter from `PolishChatClient` is ignored — the
/// on-device model is fixed. Falls back gracefully when Apple
/// Intelligence is unavailable or the context window is exceeded.
@available(macOS 26, *)
public struct FoundationModelChatClient: PolishChatClient {

    public init() {}

    public func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        let availability = SystemLanguageModel.default.availability
        guard availability == .available else {
            throw FoundationModelError.unavailable(availability)
        }

        // Use permissive guardrails since we're transforming the
        // user's own dictated text, not generating new content. The
        // default guardrails refuse to process inputs that contain
        // words like "wrong" or "no" in certain combinations.
        let llm = SystemLanguageModel(
            guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(
            model: llm,
            instructions: systemPrompt)

        let response = try await session.respond(to: userPrompt)
        let text = response.content.trimmingCharacters(
            in: .whitespacesAndNewlines)

        // The on-device model sometimes returns preamble instead of
        // cleaned text. Detect and return empty so the caller falls
        // back to deterministic polish.
        if Self.isRefusalOrPreamble(text) { return "" }
        return text
    }

    /// Detect model responses that are preamble or meta-commentary
    /// rather than cleaned transcript text.
    static func isRefusalOrPreamble(_ text: String) -> Bool {
        let lower = text.lowercased()
        let markers = [
            "i apologize", "i cannot", "i'm sorry", "i am sorry",
            "i'm just an ai", "i am just an ai",
            "sorry, but", "sorry but i",
            "sure, here", "sure! here", "here is the",
            "here's the", "here are the", "here is your",
            "no problem", "okay, here", "of course,",
            "no wait, i meant",
            "sure, i can help",
        ]
        for marker in markers {
            if lower.hasPrefix(marker) { return true }
        }
        return false
    }

    public enum FoundationModelError: Error, LocalizedError {
        case unavailable(SystemLanguageModel.Availability)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let availability):
                return "On-device model unavailable: \(availability)"
            }
        }
    }
}
#endif
