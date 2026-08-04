import Foundation

/// Match a call turn's utterance against a fixed set of command
/// phrases.
///
/// The whole utterance must be the command — a phrase inside a longer
/// sentence stays content, so speech about hanging up is still sent
/// to the agent. Matching ignores case, punctuation, and whitespace,
/// because transcription and polish add all three.
public struct PhraseMetaCommandInterpreter: MetaCommandInterpreting {

    /// "End the conversation" is the promoted phrase — it matches the
    /// visual language. Natural variants ("this", "let's …") and the
    /// call-metaphor forms stay as unadvertised aliases so
    /// recognition is forgiving. The normalizer strips punctuation,
    /// so "let's" matches as "lets".
    private static let phrases: [String: CallMetaCommand] = [
        "end the conversation": .hangUp,
        "end this conversation": .hangUp,
        "end conversation": .hangUp,
        "lets end the conversation": .hangUp,
        "lets end this conversation": .hangUp,
        "end the call": .hangUp,
        "hang up": .hangUp,
        "hang up the call": .hangUp,
    ]

    public init() {}

    public func interpret(_ utterance: String) async -> CallMetaCommand? {
        Self.phrases[Self.normalize(utterance)]
    }

    private static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
