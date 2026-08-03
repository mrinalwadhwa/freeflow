import Foundation

/// Split a speech script into chunks a Kokoro pass can synthesize.
///
/// Kokoro caps one pass at 510 phoneme tokens, and one pass produces one
/// uninterruptible stretch of generation, so chunks also bound how long
/// the first audio takes and how promptly a stop lands. Chunks break at
/// sentence boundaries, packing whole sentences up to the limit; a single
/// overlong sentence splits at word boundaries.
enum KokoroSpeechChunker {

    /// A conservative character budget per pass: phoneme tokens roughly
    /// track characters, so this stays well under the model's cap while
    /// keeping chunks long enough for natural phrasing across a sentence.
    static let defaultMaximumLength = 350

    static func chunks(
        from text: String,
        maximumLength: Int = defaultMaximumLength
    ) -> [String] {
        let sentences = sentences(in: text)
        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(trimmed)
            }
            current = ""
        }

        for sentence in sentences {
            if sentence.count > maximumLength {
                flush()
                chunks.append(
                    contentsOf: wordSplits(
                        of: sentence, maximumLength: maximumLength))
                continue
            }
            if current.isEmpty {
                current = sentence
            } else if current.count + 1 + sentence.count <= maximumLength {
                current += " " + sentence
            } else {
                flush()
                current = sentence
            }
        }
        flush()
        return chunks
    }

    /// Split text into sentences on terminal punctuation and line breaks,
    /// keeping the punctuation with its sentence.
    private static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
            current = ""
        }

        var iterator = text.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            if character == "\n" {
                flush()
                continue
            }
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                // Terminal punctuation ends the sentence only before
                // whitespace, so decimals, versions, and dotted names
                // stay whole.
                let next = iterator.next()
                if next == nil || next == " " || next == "\n" {
                    flush()
                    pending = next == "\n" ? next : nil
                } else {
                    pending = next
                }
            }
        }
        flush()
        return sentences
    }

    private static func wordSplits(
        of sentence: String, maximumLength: Int
    ) -> [String] {
        var splits: [String] = []
        var current = ""
        for word in sentence.split(separator: " ") {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= maximumLength {
                current += " " + word
            } else {
                splits.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty {
            splits.append(current)
        }
        return splits
    }
}
