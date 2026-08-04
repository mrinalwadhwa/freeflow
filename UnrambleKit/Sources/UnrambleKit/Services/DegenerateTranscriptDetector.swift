import Foundation

/// Detect a recognizer's hallucination loops in a finished utterance.
///
/// A recognizer fed minutes of marginal audio — keyboard noise, room
/// sounds, half-voiced muttering under an always-open microphone —
/// falls into loops, repeating whole invented sentences verbatim.
/// Live testing produced turns like "I'm not sure if I'm going to be
/// able to do it." four times in a row. Real speech essentially never
/// repeats identical long sentences for half of an utterance, so
/// heavy exact repetition is judged noise and vetoed before it can
/// inject into the agent's prompt. Text can never authorize a send;
/// this check only ever removes one.
public enum DegenerateTranscriptDetector {

    /// Sentences shorter than this many words are ignored: repeated
    /// short interjections — "yes, yes, yes" — are how people talk.
    private static let minimumSentenceWords = 4

    /// Loop detection needs enough sentences to call a pattern.
    private static let minimumSentenceCount = 4

    /// The fraction of sentences that are exact repeats of an earlier
    /// one before the utterance is judged a loop.
    private static let repeatedFractionThreshold = 0.5

    /// Whole-turn transcripts that recognizers invent from
    /// near-silence. The set is tiny and famous — trailing-noise
    /// decodes converge on polite sign-offs — and a call turn that
    /// is nothing but one of them is noise, not speech.
    private static let silenceInventions: Set<String> = [
        "thank you",
        "thank you very much",
        "thanks for watching",
        "thank you for watching",
        "i m going to go to the next slide",
        "i ll see you in the next video",
        "see you in the next video",
    ]

    public static func isDegenerate(_ text: String) -> Bool {
        let whole = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if silenceInventions.contains(whole) { return true }
        let sentences = normalizedSentences(in: text)
        // Three identical long sentences and nothing else is already a
        // loop — live floods arrived exactly one sentence under the
        // pattern minimum. A person repeating one long sentence three
        // times verbatim with zero variation is not how speech works.
        if sentences.count == 3, Set(sentences).count == 1 {
            return true
        }
        guard sentences.count >= minimumSentenceCount else { return false }
        let unique = Set(sentences).count
        let repeated = 1.0 - Double(unique) / Double(sentences.count)
        return repeated >= repeatedFractionThreshold
    }

    /// Split into lowercased, punctuation-free sentences of at least
    /// the minimum length, so repeats compare on their words alone.
    private static func normalizedSentences(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { sentence in
                sentence
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                    .filter { !$0.isEmpty }
            }
            .filter { $0.count >= minimumSentenceWords }
            .map { $0.joined(separator: " ") }
    }
}
