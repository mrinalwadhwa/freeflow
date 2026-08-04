import Foundation

/// Turns readable content into the text a synthesizer speaks.
///
/// A deliberately small placeholder for the speech-shaping stage: it
/// speaks attribution and title first, reads prose, headings, list items,
/// and quotes as they are, and announces code blocks by size instead of
/// reading them. Fuller shaping (URL and identifier normalization, link
/// list elision) replaces this type without touching acquisition.
public struct SpeechScriptBuilder: Sendable {

    public init() {}

    public func script(for content: ReadableContent) -> String {
        var lines: [String] = []
        if let attribution = content.attribution, !attribution.isEmpty {
            lines.append("\(Self.normalizeForSpeech(attribution)).")
        }
        if let title = content.title, !title.isEmpty {
            lines.append("\(Self.normalizeForSpeech(title)).")
        }
        for segment in content.segments {
            switch segment.kind {
            case .prose, .listItem, .quote, .metadata:
                lines.append(Self.normalizeForSpeech(segment.text))
            case .heading:
                lines.append("\(Self.normalizeForSpeech(segment.text)).")
            case .code:
                // A one-line block is usually a command; the full formal
                // announcement grates when several appear in a row.
                let lineCount = segment.text
                    .components(separatedBy: "\n").count
                if lineCount == 1 {
                    lines.append("Command skipped.")
                } else {
                    lines.append("Code block, \(lineCount) lines, skipped.")
                }
            }
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spoken glyph replacements, applied to every spoken segment.
    /// Synthesizers stumble on symbol characters and UI glyphs —
    /// key symbols, button marks, separators — so they are replaced
    /// with the words a person would say.
    private static let spokenGlyphs: [(String, String)] = [
        ("✕", "x"),
        ("✗", "x"),
        ("✓", "checkmark"),
        ("✔", "checkmark"),
        ("■", "square"),
        ("⌃", "control-"),
        ("⇧", "shift-"),
        ("⌥", "option-"),
        ("⌘", "command-"),
        ("→", " to "),
        (" · ", ", "),
    ]

    /// The spoken names of letters, for option labels. Written out
    /// as words because voices read bare letters unreliably.
    private static let letterNames: [String: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee",
        "f": "eff", "g": "jee", "h": "aitch", "i": "eye", "j": "jay",
        "k": "kay", "l": "ell", "m": "em", "n": "en", "o": "oh",
        "p": "pee", "q": "cue", "r": "arr", "s": "ess", "t": "tee",
        "u": "you", "v": "vee", "w": "double-you", "x": "ex",
        "y": "why", "z": "zee",
    ]

    /// Rewrite glyphs and label patterns into speakable words. A
    /// parenthesized single letter is an option label — "(a)" reads
    /// as "option a" — and key-symbol runs like ⌃⇧C become
    /// "control-shift-C".
    static func normalizeForSpeech(_ text: String) -> String {
        var result = text
        for (glyph, spoken) in spokenGlyphs {
            result = result.replacingOccurrences(of: glyph, with: spoken)
        }
        // Spell the label as the letter's name: voices read a bare
        // "a" as the article — even uppercase — so the name is
        // written out as a word no pronunciation model can miss.
        result = result.replacing(#/\(([A-Za-z])\)/#) { match in
            let letter = String(match.output.1).lowercased()
            let name = letterNames[letter] ?? letter.uppercased()
            return "option \(name),"
        }
        // A commit-style hex hash reads as one mangled word; spell
        // it character by character. Requiring both a digit and a
        // hex letter keeps ordinary words and plain numbers intact.
        result = result.replacing(
            #/\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b/#
        ) { match in
            match.output.map { character in
                letterNames[String(character)] ?? String(character)
            }.joined(separator: "-")
        }
        // The label rewrite can double punctuation at a sentence end.
        result = result.replacingOccurrences(of: ",.", with: ".")
        result = result.replacingOccurrences(of: ",,", with: ",")
        return result
    }
}
