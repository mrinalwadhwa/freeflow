import Foundation

/// Judge whether a transcript fragment stops mid-clause.
///
/// The recognizer punctuates fragments — "make a list of." gets a
/// period — so punctuation cannot mark completeness. A trailing
/// function word is the reliable sign that the speaker paused to
/// think rather than finished; a conversation call holds its
/// endpoint open a little longer when it sees one.
public enum MidClauseHeuristics {

    /// Words that end a clause only when the thought is unfinished.
    private static let trailingFunctionWords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "with",
        "and", "or", "but", "so", "because", "if", "that", "than",
        "as", "by", "from", "into", "onto", "over", "under", "about",
        "between", "during", "before", "after", "since", "until",
        "unless", "although", "though", "toward", "towards", "upon",
        "within", "without", "against", "through", "among", "along",
        "across", "despite", "whether", "either", "neither", "nor",
        "is", "are", "was", "were", "be", "been",
        "being", "am", "will", "would", "can", "could", "should",
        "shall", "may", "might", "must", "do", "does", "did", "has",
        "have", "had", "my", "your", "his", "her", "its", "our",
        "their", "whose", "this", "these", "those", "when", "where",
        "while", "which", "who", "what", "how", "why", "very",
        "really", "quite", "some", "any", "each", "every", "more",
        "most", "less", "i", "you", "he", "she", "we", "they", "me",
        "him", "them", "us", "not", "no",
    ]

    /// Whether the fragment's last word suggests an unfinished
    /// thought. Empty text is not mid-clause: with nothing to judge,
    /// the endpoint keeps its ordinary timing.
    public static func endsMidClause(_ transcript: String) -> Bool {
        guard
            let lastToken = transcript
                .split(whereSeparator: \.isWhitespace).last
        else { return false }
        let word = lastToken
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        guard !word.isEmpty else { return false }
        return trailingFunctionWords.contains(word)
    }
}
