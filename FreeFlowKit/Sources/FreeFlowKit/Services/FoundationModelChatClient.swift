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

        let session = LanguageModelSession(
            model: .default,
            instructions: systemPrompt)

        let response = try await session.respond(to: userPrompt)
        return response.content.trimmingCharacters(
            in: .whitespacesAndNewlines)
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
