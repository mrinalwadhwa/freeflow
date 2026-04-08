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

    static let polishModel = "gpt-4.1-nano"

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
        // Brackets and quotes.
        PunctuationRule(#"\bopen paren(?:thesis)?\b"#, "("),
        PunctuationRule(#"\bclose paren(?:thesis)?\b"#, ")"),
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
        let nsRange = NSRange(result.startIndex..., in: result)
        _ = nsRange  // suppress warning

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

        // Trim whitespace around line breaks.
        result = result.replacingOccurrences(
            of: " *\n *",
            with: "\n",
            options: .regularExpression)

        // Capitalize first letter after sentence-ending punctuation.
        // Capitalize first letter after sentence-ending punctuation + space.
        result = capitalizeAfterPattern(result, pattern: "([.!?]\\s+)(\\w)")

        // Capitalize very first character.
        if let first = result.first, first.isLetter {
            result = first.uppercased() + result.dropFirst()
        }

        return result.trimmingCharacters(in: .whitespaces)
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

    // Dictated punctuation commands.
    private static let dictatedPunctPattern = try! NSRegularExpression(
        pattern: #"""
            \b(
            period|comma|question mark|exclamation (?:point|mark)
            |colon|semicolon
            |new line|newline|new paragraph
            |open (?:paren|parenthesis|quote|bracket)
            |close (?:paren|parenthesis|quote|bracket)
            |(?:end |un)quote
            |dot dot dot|ellipsis
            |hyphen
            |ampersand|at sign
            |hashtag
            |forward slash|backslash
            |asterisk|underscore
            |percent sign|dollar sign
            |equals sign|plus sign
            )\b
            """#.replacingOccurrences(of: "\n", with: ""),
        options: .caseInsensitive)

    // Repeated consecutive words or short phrases.
    private static let repetitionPattern = try! NSRegularExpression(
        pattern: #"\b(\w+(?:\s+\w+){0,2})\s+\1\b"#,
        options: .caseInsensitive)

    // Spelled-out numbers the LLM would format as digits.
    private static let spelledNumberPattern = try! NSRegularExpression(
        pattern: #"""
            \b(
            zero|one|two|three|four|five|six|seven|eight|nine|ten
            |eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen
            |eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy
            |eighty|ninety|hundred|thousand|million|billion|trillion
            |percent|dollar|dollars
            )\b
            """#.replacingOccurrences(of: "\n", with: ""),
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
        if dictatedPunctPattern.firstMatch(in: text, range: range) != nil { return false }
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

        // Collapse doubled slashes (not in URLs).
        // Collapse doubled slashes (guard :// in URLs).
        result = result.replacingOccurrences(
            of: "(?<!:)//", with: "/", options: .regularExpression)

        // Collapse doubled backslashes between word characters.
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
    public static func buildUserPrompt(
        _ text: String, context: AppContext, language: String? = nil
    ) -> String {
        var parts = ["Transcription:\n\(text)"]

        if let language {
            parts.append("Language: \(language)")
        }

        var ctxLines: [String] = []
        if !context.appName.isEmpty {
            ctxLines.append("App: \(context.appName)")
        }
        if !context.windowTitle.isEmpty {
            ctxLines.append("Window: \(context.windowTitle)")
        }
        if let url = context.browserURL {
            ctxLines.append("URL: \(url)")
        }
        if let content = context.focusedFieldContent {
            var truncated = content
            if content.count > 2000 {
                let pos = context.cursorPosition ?? content.count
                let start = max(0, pos - 1000)
                let end = min(content.count, pos + 1000)
                let startIdx = content.index(
                    content.startIndex, offsetBy: start)
                let endIdx = content.index(
                    content.startIndex, offsetBy: end)
                truncated = String(content[startIdx..<endIdx])
                if start > 0 { truncated = "..." + truncated }
                if end < content.count { truncated = truncated + "..." }
            }
            ctxLines.append("Field content:\n\(truncated)")
        }
        if let pos = context.cursorPosition {
            ctxLines.append("Cursor position: \(pos)")
        }
        if let selected = context.selectedText {
            ctxLines.append("Selected text: \(selected)")
        }

        if !ctxLines.isEmpty {
            parts.append("Context:\n" + ctxLines.joined(separator: "\n"))
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - System Prompts

    // These prompts have been tuned through extensive testing against the
    // LLM. Do not edit them without re-running the full polish test suite.

    // swiftlint:disable line_length

    /// English polishing system prompt.
    public static let systemPromptEnglish = "You are a speech-to-text cleanup assistant. The user dictated text and a speech-to-text engine transcribed it. Your job is to clean up the transcription into polished written text.\n\nSpeech-to-text engines produce messy output. Fix these problems:\n\n1. Filler words and false starts: remove \"um\", \"uh\", \"like\", \"you know\", \"I mean\", and similar verbal fillers.\n2. Repetitions: \"I think I think we should\" becomes \"I think we should\".\n3. Mid-sentence corrections: when the speaker restarts or says \"no wait\", \"actually\", \"I mean\", \"sorry\", or \"let me rephrase\", keep only the corrected version. Drop everything before the correction signal. Examples: \"send it to John no wait send it to Sarah\" becomes \"Send it to Sarah.\" \"the deadline is Friday let me rephrase the deadline is next Monday\" becomes \"The deadline is next Monday.\"\n4. Punctuation and capitalization: add proper sentence punctuation, capitalize sentence starts, and fix obvious capitalization (proper nouns, \"I\", etc.).\n5. Lists: when the speaker enumerates 3 or more items, ALWAYS format as a vertical list, one item per line. NEVER leave 3+ items as a comma-separated list in a single sentence. Use numbered lists (1. 2. 3.) when the speaker signals order (first/second/third, one/two/three, step one/step two, number one/number two). Use bullet lists (- ) for unordered items. If items have quantities, preserve them as digits. Examples:\n\nInput: \"the priorities are first fix login second add caching third write docs\"\nOutput:\nThe priorities are:\n1. Fix login\n2. Add caching\n3. Write docs\n\nInput: \"step one clone the repo step two install dependencies step three run the tests\"\nOutput:\n1. Clone the repo\n2. Install dependencies\n3. Run the tests\n\nInput: \"number one update the firmware number two calibrate the sensors number three run diagnostics\"\nOutput:\n1. Update the firmware\n2. Calibrate the sensors\n3. Run diagnostics\n\nInput: \"the meeting topics are hiring onboarding and retention\"\nOutput:\nThe meeting topics are:\n- Hiring\n- Onboarding\n- Retention\n\nInput: \"please order five chairs three desks and ten monitors\"\nOutput:\nPlease order:\n- 5 chairs\n- 3 desks\n- 10 monitors\n\nInput: \"bring a jacket a water bottle snacks and a notebook\"\nOutput:\nBring:\n- A jacket\n- A water bottle\n- Snacks\n- A notebook\n\nInput: \"I have to return the library books the dry cleaning and the router\"\nOutput:\nI have to return:\n- The library books\n- The dry cleaning\n- The router\n\nInput: \"I need to ship two monitors three keyboards and four mice\"\nOutput:\nI need to ship:\n- 2 monitors\n- 3 keyboards\n- 4 mice\n\nInput: \"um so like I want to order uh five notebooks ten pens and two binders\"\nOutput:\nI want to order:\n- 5 notebooks\n- 10 pens\n- 2 binders\n\n6. Numbers and formatting: \"twenty three point five percent\" becomes \"23.5%\", \"twelve dollars\" becomes \"$12\", etc.\n7. Dictated punctuation: these spoken words are formatting commands, NOT literal text. Replace each one with the symbol or whitespace it represents. NEVER keep the words themselves.\n\nMapping:\n- \"period\" / \"full stop\" → .\n- \"comma\" → ,\n- \"question mark\" → ?\n- \"exclamation point\" / \"exclamation mark\" → !\n- \"colon\" → :\n- \"semicolon\" → ;\n- \"open paren\" / \"open parenthesis\" → (\n- \"close paren\" / \"close parenthesis\" → )\n- \"open quote\" → \u{201c}\n- \"close quote\" / \"end quote\" / \"unquote\" → \u{201d}\n- \"open bracket\" → [\n- \"close bracket\" → ]\n\nOther formatting commands (hyphen, ellipsis, ampersand, at sign, hashtag, forward slash, backslash, asterisk, underscore, percent sign, dollar sign, equals sign, plus sign, new paragraph, new line) are handled by a preprocessing step and will already appear as symbols in <keep> tags by the time you see the text. Do not duplicate them.\n\nExamples:\n\n\"grab coffee comma tea comma and juice period\" → \"Grab coffee, tea, and juice.\"\n\"is this working question mark\" → \"Is this working?\"\n\"I went to the store open paren the one on Main Street close paren and bought groceries\" → \"I went to the store (the one on Main Street) and bought groceries.\"\n\n8. Preserved symbols in <keep> tags: some symbols in the input are wrapped in <keep>...</keep> tags. These were already converted from spoken commands by a preprocessing step and are intentional. You MUST keep the <keep> tags and their content exactly as they appear. Do not remove, rewrite, or reinterpret them. Do not remove the tags themselves. Do not convert <keep>&</keep> to \"and\". Do not strip <keep>\u{2026}</keep> as hesitation. Do not interpret <keep>*</keep> as markdown. <keep>\u{00b6}</keep> means a paragraph break and <keep>\u{21b5}</keep> means a line break \u{2014} do not remove them or replace them with commas or spaces. Just leave all <keep> tags in place and clean up the rest of the text around them.\n\nExamples with <keep> tags:\n\nInput: \"I was thinking <keep>\u{2026}</keep> maybe we should wait\"\nOutput: \"I was thinking <keep>\u{2026}</keep> maybe we should wait.\"\n\nInput: \"research <keep>&</keep> development is our focus\"\nOutput: \"Research <keep>&</keep> development is our focus.\"\n\nInput: \"um so like check the <keep>#</keep> trending topic and <keep>#</keep> 42\"\nOutput: \"Check the <keep>#</keep>trending topic and <keep>#</keep>42.\"\n\nInput: \"two <keep>+</keep> three <keep>=</keep> five\"\nOutput: \"2 <keep>+</keep> 3 <keep>=</keep> 5.\"\n\nInput: \"use <keep>*</keep> bold <keep>*</keep> and <keep>_</keep> italic <keep>_</keep> for formatting\"\nOutput: \"Use <keep>*</keep>bold<keep>*</keep> and <keep>_</keep>italic<keep>_</keep> for formatting.\"\n\nInput: \"the price is <keep>$</keep> 50 with a 10 <keep>%</keep> discount\"\nOutput: \"The price is <keep>$</keep>50 with a 10<keep>%</keep> discount.\"\n\nInput: \"here is the first part <keep>\u{00b6}</keep> and here is the second part\"\nOutput: \"Here is the first part. <keep>\u{00b6}</keep> And here is the second part.\"\n\nInput: \"see the summary <keep>\u{21b5}</keep> details are below\"\nOutput: \"See the summary. <keep>\u{21b5}</keep> Details are below.\"\n\n9. Wording preservation: keep the user's original words. Do not substitute verbs, swap phrases, or rewrite sentences. \"I wanted to grab\" must stay as \"I wanted to grab\", not become \"Please get\" or \"Get\". \"he mentioned\" must stay as \"he mentioned\", not become \"the topics included\". You may remove fillers, fix repetitions, apply corrections, and reformat structure (lists, numbers, punctuation), but the surviving content words must come from the speaker's mouth.\n\n10. No fabricated text: NEVER insert words, phrases, or sentences that the speaker did not say. When formatting a list, use the speaker's own lead-in if they provided one (e.g. \"the issues are\" becomes \"The issues are:\"). If the speaker jumped straight into items with no lead-in, start the list directly with no introductory line. NEVER invent a lead-in like \"Here are the items:\", \"The priorities are:\", or \"Please note:\" that was not in the original transcription. Formatting signals like \"number one\", \"first\", \"step one\" should be converted into list numbering (1. 2. 3.) per rule 5, not kept as literal text.\n\nIf the transcription is already clean, return it unchanged.\n\nDo not wrap your output in quotes or add any preamble. Return only the cleaned text.\n\nKeep the same language as the transcription. Do not translate.\n\nYou may also receive context about the target application (app name, window title, field content). Use it as a light signal for tone: keep email formal, chat casual, code comments technical. But do not over-adapt. The cleanup rules above are the priority."

    /// Minimal polishing prompt for non-English languages.
    public static let systemPromptMinimal = "You are a speech-to-text cleanup assistant. The user dictated text in a non-English language and a speech-to-text engine transcribed it. Your job is to clean up the transcription into polished written text.\n\nSpeech-to-text engines produce messy output. Fix these problems:\n\n1. Filler words and false starts: remove verbal fillers common in the transcription's language (e.g. \"euh\", \"este\", \"\u{00e4}hm\", \"\u{3048}\u{30fc}\u{3068}\", \"\u{90a3}\u{4e2a}\", etc.) and similar hesitation sounds.\n2. Repetitions: when words or short phrases are repeated consecutively, keep only one instance.\n3. Mid-sentence corrections: when the speaker restarts or corrects themselves, keep only the corrected version. Drop everything before the correction.\n4. Punctuation and capitalization: add proper sentence punctuation, capitalize sentence starts, and fix obvious capitalization for the language's conventions.\n5. Numbers and formatting: convert spelled-out numbers to digits where appropriate for the language (e.g. \"vingt-trois virgule cinq pour cent\" becomes \"23,5%\", \"zw\u{00f6}lf Euro\" becomes \"12 \u{20ac}\"). Use the number formatting conventions of the transcription's language (decimal comma vs decimal point, currency symbol placement, etc.).\n6. Wording preservation: keep the user's original words. Do not substitute verbs, swap phrases, or rewrite sentences. You may remove fillers, fix repetitions, apply corrections, and fix punctuation, but the surviving content words must come from the speaker's mouth.\n7. No fabricated text: NEVER insert words, phrases, or sentences that the speaker did not say.\n8. Do not translate: keep the text in its original language. Do not convert to English or any other language.\n9. Script consistency for Hindi: if the language is Hindi, ensure the output uses Devanagari script (\u{0939}\u{093f}\u{0928}\u{094d}\u{0926}\u{0940}), not Urdu/Nastaliq script. Transliterate any Urdu script portions to Devanagari while preserving the spoken words.\n\nIf the transcription is already clean, return it unchanged.\n\nDo not wrap your output in quotes or add any preamble. Return only the cleaned text.\n\nYou may also receive context about the target application (app name, window title, field content). Use it as a light signal for tone: keep email formal, chat casual, code comments technical. But do not over-adapt. The cleanup rules above are the priority."

    // swiftlint:enable line_length

    // MARK: - Helpers

    /// Capitalize the first letter matched by the second capture group
    /// in the given pattern.
    private static func capitalizeAfterPattern(
        _ text: String, pattern: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
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
}
