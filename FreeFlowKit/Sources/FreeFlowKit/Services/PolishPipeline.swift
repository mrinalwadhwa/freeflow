import Foundation

/// Three-stage text polishing pipeline for dictation transcripts.
///
/// Refine raw speech-to-text output into polished written text:
///
/// 1. **Dictated punctuation substitution** — deterministic regex
///    replacements for spoken formatting commands ("period", "comma",
///    "new paragraph"). Protected symbols wrapped in `<keep>` tags.
///
/// 2. **Clean transcript skip** — heuristic that bypasses the LLM
///    when the transcript is already well-formed.
///
/// 3. **LLM refinement** — send to a small model that removes fillers,
///    fixes repetitions, formats lists/numbers, and adjusts tone.
public enum PolishPipeline {

    // MARK: - Configuration

    public static let polishModel = "gpt-4.1-nano"

    // MARK: - Stage 1: Dictated Punctuation Substitution

    /// A substitution rule: regex pattern, replacement string, and
    /// whether to wrap the replacement in `<keep>` tags.
    private struct PunctuationRule {
        let pattern: NSRegularExpression
        let replacement: String
        let protect: Bool

        init(_ pattern: String, _ replacement: String, protect: Bool = false) {
            // swiftlint:disable:next force_try
            self.pattern = try! NSRegularExpression(
                pattern: pattern, options: .caseInsensitive)
            self.replacement = replacement
            self.protect = protect
        }
    }

    // Order matters: "new paragraph" must come before "period" to avoid
    // partial matches.
    private static let punctuationRules: [PunctuationRule] = [
        // Paragraph and line breaks.
        PunctuationRule(#"\bnew paragraph\b"#, "\u{00b6}", protect: true),
        PunctuationRule(#"\bnew line\b"#, "\u{21b5}", protect: true),
        PunctuationRule(#"\bnewline\b"#, "\u{21b5}", protect: true),
        // Sentence-ending punctuation.
        PunctuationRule(#"\bperiod\b"#, "."),
        PunctuationRule(#"\bfull stop\b"#, "."),
        PunctuationRule(#"\bquestion mark\b"#, "?"),
        PunctuationRule(#"\bexclamation point\b"#, "!"),
        PunctuationRule(#"\bexclamation mark\b"#, "!"),
        // Inline punctuation.
        PunctuationRule(#"\bcomma\b"#, ","),
        PunctuationRule(#"\bcolon\b"#, ":"),
        PunctuationRule(#"\bsemicolon\b"#, ";"),
        // Brackets and quotes. "parent" is a common STT misrecognition
        // for "paren" because "paren" isn't a standalone English word,
        // so we accept it as an alias.
        PunctuationRule(#"\bopen paren(?:t|thesis)?\b"#, "("),
        PunctuationRule(#"\bclose paren(?:t|thesis)?\b"#, ")"),
        PunctuationRule(#"\bopen quote\b"#, "\u{201c}"),
        PunctuationRule(#"\b(?:close|end) quote\b"#, "\u{201d}"),
        PunctuationRule(#"\bunquote\b"#, "\u{201d}"),
        PunctuationRule(#"\bopen bracket\b"#, "["),
        PunctuationRule(#"\bclose bracket\b"#, "]"),
        // Symbols (protected — the LLM might reinterpret these).
        PunctuationRule(#"\bdot dot dot\b"#, "\u{2026}", protect: true),
        PunctuationRule(#"\bellipsis\b"#, "\u{2026}", protect: true),
        PunctuationRule(#"\bhyphen\b"#, "-", protect: true),
        PunctuationRule(#"\bampersand\b"#, "&", protect: true),
        PunctuationRule(#"\bat sign\b"#, "@", protect: true),
        PunctuationRule(#"\bhashtag\b"#, "#", protect: true),
        PunctuationRule(#"\bforward slash\b"#, "/", protect: true),
        PunctuationRule(#"\bbackslash\b"#, "\\", protect: true),
        PunctuationRule(#"\basterisk\b"#, "*", protect: true),
        PunctuationRule(#"\bunderscore\b"#, "_", protect: true),
        PunctuationRule(#"\bpercent sign\b"#, "%", protect: true),
        PunctuationRule(#"\bdollar sign\b"#, "$", protect: true),
        PunctuationRule(#"\bequals sign\b"#, "=", protect: true),
        PunctuationRule(#"\bplus sign\b"#, "+", protect: true),
    ]

    /// Replace spoken punctuation commands with actual symbols.
    ///
    /// Protected symbols are wrapped in `<keep>` tags so the LLM
    /// preserves them verbatim.
    public static func substituteDictatedPunctuation(_ text: String) -> String {
        var result = text

        for rule in punctuationRules {
            let replacement: String
            if rule.protect {
                replacement = "<keep>\(rule.replacement)</keep>"
            } else {
                replacement = rule.replacement
            }

            // Use a block-based replacement to avoid NSRegularExpression
            // interpreting backslashes in the replacement string.
            var output = ""
            var lastEnd = result.startIndex
            let matches = rule.pattern.matches(
                in: result,
                range: NSRange(result.startIndex..., in: result))

            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                output += result[lastEnd..<range.lowerBound]
                output += replacement
                lastEnd = range.upperBound
            }
            output += result[lastEnd...]
            result = output
        }

        // Clean up whitespace around punctuation introduced by substitution.
        // Remove spaces before punctuation that attaches to preceding word.
        // Non-raw strings so \u{...} is interpreted as Unicode.
        result = result.replacingOccurrences(
            of: " +([.,;:?!)\\]\u{201d}])",
            with: "$1",
            options: .regularExpression)

        // Remove spaces after opening brackets/quotes.
        result = result.replacingOccurrences(
            of: "([(\\[\u{201c}]) +",
            with: "$1",
            options: .regularExpression)

        // Collapse multiple spaces.
        result = result.replacingOccurrences(
            of: " {2,}",
            with: " ",
            options: .regularExpression)

        // Collapse runs of adjacent punctuation down to the strongest
        // single mark. The Realtime STT already inserts commas and
        // periods from pauses and prosody, so when the user also
        // dictates "comma" or "period" the substitution above emits
        // duplicates. "Hey team,,," becomes "Hey team,". "breaks,."
        // becomes "breaks.".
        result = collapseAdjacentPunctuation(result)

        // Trim whitespace around line breaks.
        result = result.replacingOccurrences(
            of: " *\n *",
            with: "\n",
            options: .regularExpression)

        // Capitalize first letter after sentence-ending punctuation + space.
        result = capitalizeAfterPattern(result, pattern: "([.!?]\\s+)(\\w)")

        // Capitalize very first character.
        if let first = result.first, first.isLetter {
            result = first.uppercased() + result.dropFirst()
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Strength ordering used by `collapseAdjacentPunctuation`: stronger
    /// punctuation wins when multiple marks sit adjacent to each other.
    /// Values are arbitrary but ordered `, < : < ; < . < ? < !`.
    private static let punctuationStrength: [Character: Int] = [
        ",": 1,
        ":": 2,
        ";": 3,
        ".": 4,
        "?": 5,
        "!": 6,
    ]

    private static let adjacentPunctuationPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"([.,;:?!])(?:\s*[.,;:?!])+"#,
            options: [])
    }()

    /// Collapse runs of adjacent punctuation marks (possibly separated by
    /// whitespace) down to the single strongest one in the run. Used to
    /// clean up duplicates produced when the STT auto-inserts punctuation
    /// from pauses *and* the user dictates a punctuation command in the
    /// same spot.
    static func collapseAdjacentPunctuation(_ text: String) -> String {
        let matches = adjacentPunctuationPattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastEnd = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[lastEnd..<range.lowerBound]
            let run = text[range]
            let strongest = run.compactMap { punctuationStrength[$0] != nil ? $0 : nil }
                .max(by: { punctuationStrength[$0]! < punctuationStrength[$1]! })
            if let strongest {
                result.append(strongest)
            }
            lastEnd = range.upperBound
        }
        result += text[lastEnd...]
        return result
    }

    // MARK: - Stage 2: Clean Transcript Detection

    // Filler words and verbal corrections.
    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"""
            \b(
            um+|uh+|er+|ah+|hmm+
            |you know|I mean
            |no wait|no,? wait
            |actually,? (?:no|wait)
            |sorry,? I mean
            |let me rephrase
            )\b
            """#.replacingOccurrences(of: "\n", with: ""),
        options: .caseInsensitive)

    // Repeated consecutive words or short phrases.
    private static let repetitionPattern = try! NSRegularExpression(
        pattern: #"\b(\w+(?:\s+\w+){0,2})\s+\1\b"#,
        options: .caseInsensitive)

    // Spelled-out compound numbers the LLM would format as digits.
    // Requires two adjacent number-words or a number-word followed by a
    // quantity marker so isolated words like "one" or "two" don't match.
    private static let numberWord = """
        (?:zero|one|two|three|four|five|six|seven|eight|nine|ten\
        |eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen\
        |eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy\
        |eighty|ninety)
        """
    private static let multiplier = """
        (?:hundred|thousand|million|billion|trillion)
        """
    private static let quantityMarker = """
        (?:percent|dollar|dollars)
        """
    private static let spelledNumberPattern = try! NSRegularExpression(
        pattern: #"\b(?:"# + numberWord + #"\s+"# + numberWord
            + #"|"# + numberWord + #"\s+"# + multiplier
            + #"|"# + numberWord + #"\s+"# + quantityMarker
            + #"|"# + multiplier + #"\s+"# + numberWord
            + #")\b"#,
        options: .caseInsensitive)

    /// Check if a transcript is clean enough to skip LLM polishing.
    ///
    /// Conservative: when in doubt, return false so the LLM gets called.
    public static func isClean(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // Must start with an uppercase letter.
        guard let first = text.first, first.isUppercase else { return false }

        // Must end with sentence-final punctuation.
        guard let last = text.last, ".!?".contains(last) else { return false }

        let range = NSRange(text.startIndex..., in: text)

        if fillerPattern.firstMatch(in: text, range: range) != nil { return false }
        if repetitionPattern.firstMatch(in: text, range: range) != nil { return false }
        if spelledNumberPattern.firstMatch(in: text, range: range) != nil { return false }

        return true
    }

    // MARK: - Keep Tag Processing

    private static let keepTagPattern = try! NSRegularExpression(
        pattern: #"<keep>(.*?)</keep>"#)

    /// Remove `<keep>` tags, leaving their content in place.
    ///
    /// Expand `¶` and `↵` placeholders to real line breaks. Clean up
    /// whitespace around revealed symbols.
    public static func stripKeepTags(_ text: String) -> String {
        var result = text

        // Strip tags, keep content.
        result = keepTagPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "$1")

        // Expand break placeholders to real newlines.
        // Expand pilcrow placeholder to double newline.
        result = result.replacingOccurrences(
            of: " *\u{00b6} *", with: "\n\n", options: .regularExpression)
        // Expand return arrow placeholder to single newline.
        result = result.replacingOccurrences(
            of: " *\u{21b5} *", with: "\n", options: .regularExpression)

        // Clean up whitespace around symbols that were inside tags.
        // Punctuation that attaches to preceding word.
        result = result.replacingOccurrences(
            of: " +([.,;:?!)\\]\u{201d}\u{2026}%])",
            with: "$1",
            options: .regularExpression)

        // Symbols that attach to following word.
        result = result.replacingOccurrences(
            of: "([(\\[\u{201c}#$]) +",
            with: "$1",
            options: .regularExpression)

        // Symbols that attach on both sides.
        result = result.replacingOccurrences(
            of: " *([-@/\\\\]) +",
            with: "$1",
            options: .regularExpression)

        // Collapse multiple spaces.
        result = result.replacingOccurrences(
            of: " {2,}", with: " ", options: .regularExpression)

        // Capitalize first letter after paragraph/line breaks.
        result = capitalizeAfterPattern(result, pattern: "(\\n)(\\w)")

        return result
    }

    // MARK: - Normalize Formatting

    /// Fix common LLM formatting inconsistencies.
    public static func normalizeFormatting(_ text: String) -> String {
        var result = text

        // Safety net for leaked placeholders.
        // Expand pilcrow placeholder to double newline.
        result = result.replacingOccurrences(
            of: " *\u{00b6} *", with: "\n\n", options: .regularExpression)
        // Expand return arrow placeholder to single newline.
        result = result.replacingOccurrences(
            of: " *\u{21b5} *", with: "\n", options: .regularExpression)

        // Collapse doubled slashes (guard :// in URLs).
        result = result.replacingOccurrences(
            of: "(?<!:)//", with: "/", options: .regularExpression)

        // Collapse doubled backslashes between word characters.
        result = result.replacingOccurrences(
            of: "(?<=\\w)\\\\\\\\(?=\\w)", with: "\\\\",
            options: .regularExpression)

        // Process line by line.
        // Strip trailing whitespace and normalize bullet items per line.
        let lines = result.split(
            separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        for line in lines {
            var l = String(line)
            // Strip trailing whitespace.
            while l.hasSuffix(" ") || l.hasSuffix("\t") {
                l = String(l.dropLast())
            }
            // Normalize bullet items: "-X" -> "- X".
            l = l.replacingOccurrences(
                of: "^(\\s*)-(\\S)",
                with: "$1- $2",
                options: .regularExpression)
            output.append(l)
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Context Formatting

    /// Build the user prompt for the LLM polishing call.
    /// Strip known prompt-injection markers from a context field.
    ///
    /// Remove ChatML delimiters, role-like line prefixes, and other
    /// patterns that could trick the LLM into following injected
    /// instructions embedded in window titles, URLs, or field content.
    public static func sanitizeContextField(_ text: String) -> String {
        var result = text
        // Strip ChatML delimiters.
        result = result.replacingOccurrences(of: "<|im_start|>", with: "")
        result = result.replacingOccurrences(of: "<|im_end|>", with: "")
        // Strip role-like prefixes at the start of the string or after
        // newlines (e.g. "SYSTEM:", "USER:", "ASSISTANT:").
        if let regex = try? NSRegularExpression(
            pattern: #"(?:^|\n)\s*(SYSTEM|USER|ASSISTANT)\s*:"#,
            options: .caseInsensitive
        ) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func buildUserPrompt(
        _ text: String, context: AppContext, language: String? = nil
    ) -> String {
        var parts = ["Transcription:\n\(text)"]

        if let language {
            parts.append("Language: \(language)")
        }

        var ctxLines: [String] = []
        let appName = sanitizeContextField(context.appName)
        if !appName.isEmpty {
            ctxLines.append("App: \(appName)")
        }
        let windowTitle = sanitizeContextField(context.windowTitle)
        if !windowTitle.isEmpty {
            ctxLines.append("Window: \(windowTitle)")
        }
        if let url = context.browserURL {
            ctxLines.append("URL: \(sanitizeContextField(url))")
        }
        if let content = context.focusedFieldContent {
            // cursorPosition is a UTF-16 offset from macOS accessibility
            // APIs (NSString-style). Use the utf16 view for windowing.
            var truncated: String
            let utf16Count = content.utf16.count
            if utf16Count > 2000 {
                let pos = context.cursorPosition ?? utf16Count
                let start16 = max(0, pos - 1000)
                let end16 = min(utf16Count, pos + 1000)
                let startIdx = String.Index(
                    utf16Offset: start16, in: content)
                let endIdx = String.Index(
                    utf16Offset: end16, in: content)
                truncated = String(content[startIdx..<endIdx])
                if start16 > 0 { truncated = "..." + truncated }
                if end16 < utf16Count { truncated = truncated + "..." }
            } else {
                truncated = content
            }
            // Sanitize after truncation so injection markers within the
            // cursor window are always stripped.
            truncated = sanitizeContextField(truncated)
            ctxLines.append("Field content:\n\(truncated)")
        }
        if let pos = context.cursorPosition {
            ctxLines.append("Cursor position: \(pos)")
        }
        if let selected = context.selectedText {
            ctxLines.append("Selected text: \(sanitizeContextField(selected))")
        }

        if !ctxLines.isEmpty {
            parts.append("Context:\n" + ctxLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - System Prompts

    // Prompt text is defined in the Prompts/ directory, one file per
    // prompt. Each file is a Swift extension on PolishPipeline with a
    // single multiline string literal. Edit those files to tune prompt
    // behavior; run `make test` after changes.

    /// Select the system prompt based on the transcription language.
    ///
    /// English (or nil) uses the detailed English prompt. Languages with
    /// a dedicated prompt use it; all others fall back to the minimal
    /// language-agnostic prompt.
    public static func systemPrompt(forLanguage language: String?) -> String {
        guard let language, !language.isEmpty, language != "en" else {
            return systemPromptEnglish
        }
        switch language {
        case "hi": return systemPromptHindi
        case "kn": return systemPromptKannada
        case "ta": return systemPromptTamil
        default: return systemPromptMinimal
        }
    }

    // swiftlint:enable line_length

    // MARK: - Helpers

    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        let key = pattern as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache.setObject(regex, forKey: key)
        return regex
    }

    /// Capitalize the first letter matched by the second capture group
    /// in the given pattern.
    private static func capitalizeAfterPattern(
        _ text: String, pattern: String
    ) -> String {
        guard let regex = cachedRegex(pattern) else {
            return text
        }
        var result = text
        // Process matches in reverse order to preserve ranges.
        let matches = regex.matches(
            in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard match.numberOfRanges >= 3,
                let letterRange = Range(match.range(at: 2), in: result)
            else { continue }
            let upper = result[letterRange].uppercased()
            result.replaceSubrange(letterRange, with: upper)
        }
        return result
    }

    // MARK: - Sentence Boundary Detection

    /// Whether the text ends with sentence-ending punctuation.
    ///
    /// Used by the chunk buffer to decide when accumulated raw
    /// transcripts form a complete unit worth polishing and injecting.
    /// Only checks the last non-whitespace character.
    public static func endsAtSentenceBoundary(_ text: String) -> Bool {
        guard let last = text.last(where: { !$0.isWhitespace }) else {
            return false
        }
        return last == "." || last == "?" || last == "!"
    }
}
