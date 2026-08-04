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
            case .prose, .quote, .metadata:
                lines.append(Self.normalizeForSpeech(segment.text))
            case .listItem:
                // A terminal period gives the voice a sentence break
                // between items; agents rarely punctuate list items,
                // and unbroken items run together as one rushed
                // sentence.
                let spoken = Self.normalizeForSpeech(segment.text)
                let punctuated =
                    spoken.hasSuffix(".") || spoken.hasSuffix("!")
                        || spoken.hasSuffix("?") || spoken.hasSuffix(":")
                    ? spoken : spoken + "."
                lines.append(punctuated)
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
    /// "control-shift-C". Markdown links speak their label, paths
    /// collapse to their last component, and short file extensions
    /// spell out as letters — agents write full absolute paths that
    /// are unbearable read aloud.
    static func normalizeForSpeech(_ text: String) -> String {
        var result = text
        // A markdown link's URL is for eyes; the label is the words.
        result = result.replacing(#/\[([^\]]+)\]\(([^)]+)\)/#) { match in
            String(match.output.1)
        }
        // A filesystem path reads as its last component; a trailing
        // :N is a line reference. "~/a/b/file.rs:21" becomes
        // "file.rs, line 21".
        result = result.replacing(
            #/(^|[^\w:])((?:~|\.\.?)?(?:\/[\w.@-]+){2,})(?::(\d+))?/#
        ) { match in
            let prefix = String(match.output.1)
            let path = String(match.output.2)
            let last = path.split(separator: "/").last.map(String.init)
                ?? path
            if let line = match.output.3 {
                return "\(prefix)\(last), line \(line)"
            }
            return "\(prefix)\(last)"
        }
        // A short file extension is said letter by letter:
        // "brief.md" reads as "brief dot em-dee". Latin-abbreviation
        // dots and decimal numbers stay untouched.
        result = result.replacing(
            #/\b([\w-]+)\.([a-z]{1,3})\b(?!\w)(?!\.[a-z])/#
        ) { match in
            let name = String(match.output.1)
            let ext = String(match.output.2)
            let exclusions: Set<String> = ["e", "i", "etc", "vs", "al"]
            guard !exclusions.contains(name.lowercased()),
                !exclusions.contains(ext)
            else { return String(match.output.0) }
            let spelled = ext.map { letterNames[String($0)] ?? String($0) }
                .joined(separator: "-")
            return "\(name) dot \(spelled)"
        }
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
