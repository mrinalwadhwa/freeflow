import Foundation

/// Prepare a speech script for Kokoro's phonemizer.
///
/// The phonemizer only reads plain words and basic punctuation. Numbers
/// its own expansion misreads, mixed identifiers, keyboard glyphs,
/// hyphenated compounds, markdown leftovers, arrows, and emoji either
/// garble through the out-of-vocabulary network or silently drop. The
/// normalizer turns what has a spoken reading into words and removes
/// the rest.
enum KokoroTextNormalizer {

    /// Symbols with a conventional spoken reading. Keyboard modifiers
    /// matter most: shortcut hints are common in the app's own guidance
    /// and in agent output.
    private static let spokenSymbols: [(String, String)] = [
        ("’", "'"),
        ("‘", "'"),
        ("“", "\""),
        ("”", "\""),
        ("⌃", " control "),
        ("⌥", " option "),
        ("⌘", " command "),
        ("⇧", " shift "),
        ("⎋", " escape "),
        ("⏎", " return "),
        ("×", " times "),
        ("→", " to "),
        ("…", "..."),
        ("•", ", "),
        ("%", " percent "),
    ]

    /// Punctuation the phonemizer reads or phrases around; anything
    /// outside letters, numbers, whitespace, and this set is dropped.
    private static let keptPunctuation = Set(".,;:!?'\"()%-/$&@+#=")

    /// Words the packed lexicon mispronounces, with the phonemes to use
    /// instead. The phonemizer accepts inline overrides in Misaki's
    /// `[word](/phonemes/)` form, so these survive as exact
    /// pronunciations.
    private static let pronunciationOverrides: [(String, String)] = [
        ("written", "ɹˈɪtᵊn"),
        ("Mrinal", "mɹinˈɑl"),
        ("Wadhwa", "wˈɑdwɑ"),
    ]

    /// Compounds the lexicon lacks that read fine as their plain words.
    private static let respellings: [(String, String)] = [
        ("realtime", "real time")
    ]

    static func normalize(_ text: String) -> String {
        var result = text
        // A long URL reads as garble; its host is the part worth hearing.
        result = replaceMatches(
            of: #"https?://[^\s]+"#, in: result
        ) { match in
            var host = match
            for scheme in ["https://", "http://"] {
                if host.hasPrefix(scheme) {
                    host = String(host.dropFirst(scheme.count))
                }
            }
            if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
            host = String(host.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
            return host.replacingOccurrences(of: ".", with: " dot ")
        }
        // A times sign or letter x between two numbers is a dimension
        // ("1920×1080", "1920x1080" read "by"); this must run before the
        // symbol map reads every remaining × as "times". Hex literals
        // ("0x1F") keep their x via the leading-zero guard.
        result = result.replacingOccurrences(
            of: #"(?<=\d)(?<!\b0)\s*[xX×]\s*(?=\d)"#,
            with: " by ",
            options: .regularExpression)
        for (symbol, replacement) in spokenSymbols {
            result = result.replacingOccurrences(of: symbol, with: replacement)
        }
        // Hex literals spell per character before the number rules can
        // tear them apart.
        result = replaceMatches(
            of: #"(?<![\p{L}\d])0[xX][0-9A-Fa-f]+(?![\p{L}\d])"#, in: result
        ) { match in
            match.map { character in
                character.isNumber
                    ? EnglishNumberSpeller.spellDigits(String(character))
                    : String(character)
            }.joined(separator: " ")
        }
        result = spellIdentifiers(in: result)
        // A letter x glued to the end of a number is a multiplier
        // ("1.2x", "35x") whatever follows it, as long as it does not
        // start another word.
        result = result.replacingOccurrences(
            of: #"(?<=\d)[xX](?![\p{L}\p{N}])"#,
            with: " times",
            options: .regularExpression)
        // Decimals speak their point so "1.2" reads "one point two".
        result = result.replacingOccurrences(
            of: #"(?<=\d)\.(?=\d)"#,
            with: " point ",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"\s*[—–]\s*"#,
            with: ", ",
            options: .regularExpression)
        // Hyphenated compounds miss the lexicon and garble; their plain
        // words do not.
        result = result.replacingOccurrences(
            of: #"(?<=[\p{L}\p{N}])-(?=[\p{L}\p{N}])"#,
            with: " ",
            options: .regularExpression)
        result = spellOrdinals(in: result)
        // Letters glued to a number ("24kHz") read as one unknown token;
        // split so the number and the letters each get a reading.
        result = result.replacingOccurrences(
            of: #"(?<=\d)(?=\p{L})"#,
            with: " ",
            options: .regularExpression)
        result = spellNumbers(in: result)
        result = String(
            result.map { character in
                if character.isLetter || character.isNumber
                    || character.isWhitespace
                {
                    return character
                }
                return keptPunctuation.contains(character) ? character : " "
            })
        result = result.replacingOccurrences(
            of: #" {2,}"#,
            with: " ",
            options: .regularExpression)
        // Replacements can leave a space before closing punctuation
        // ("times ."); rejoin so phrasing stays natural.
        result = result.replacingOccurrences(
            of: #" +([.,;:!?])"#,
            with: "$1",
            options: .regularExpression)
        for (word, replacement) in respellings {
            result = result.replacingOccurrences(
                of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: word)
                    + #"\b"#,
                with: replacement,
                options: .regularExpression)
        }
        // "read" is a heteronym the phonemizer always reads as present
        // tense; after an auxiliary that forces the past participle, pin
        // the past-tense sound. Ambiguous contexts keep the default.
        result = result.replacingOccurrences(
            of: #"(?i)\b(was|were|been|being|had|have|has|having|[\p{L}]+'ve) +read\b"#,
            with: "$1 [read](/ɹˈɛd/)",
            options: .regularExpression)
        // Pronunciation overrides go last: their bracket syntax must
        // reach the phonemizer intact, and the filter above would strip
        // it.
        for (word, phonemes) in pronunciationOverrides {
            result = result.replacingOccurrences(
                of: #"(?i)\b"# + NSRegularExpression.escapedPattern(for: word)
                    + #"\b"#,
                with: "[\(word)](/\(phonemes)/)",
                options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Numbers

    /// Replace standalone digit runs with their spoken words. A number
    /// written with thousands commas is a count, never a year, so it
    /// reads as a cardinal.
    private static func spellNumbers(in text: String) -> String {
        var result = replaceMatches(
            of: #"(?<![\p{L}\d])\d{1,3}(?:,\d{3})+(?![\p{L}\d])"#, in: text
        ) { match in
            let digits = match.replacingOccurrences(of: ",", with: "")
            guard let value = Int(digits), value <= 999_999 else {
                return EnglishNumberSpeller.spellDigits(digits)
            }
            return EnglishNumberSpeller.cardinal(value)
        }
        result = replaceMatches(
            of: #"(?<![\p{L}\d])\d+(?![\p{L}\d])"#, in: result
        ) { match in
            EnglishNumberSpeller.spellToken(match)
        }
        return result
    }

    /// Replace ordinals ("27th") before the digit-letter split tears
    /// their suffix off.
    private static func spellOrdinals(in text: String) -> String {
        replaceMatches(
            of: #"(?<![\p{L}\d])\d+(?:st|nd|rd|th)(?![\p{L}\d])"#, in: text
        ) { match in
            let digits = String(match.dropLast(2))
            guard let value = Int(digits), value <= 999_999 else {
                return match
            }
            return EnglishNumberSpeller.ordinal(value)
        }
    }

    // MARK: - Identifiers

    /// Spell tokens that mix letters and digits back and forth — commit
    /// hashes, identifiers — character by character, the way a person
    /// reads them. Single-boundary tokens like "24kHz" stay whole for
    /// the unit split instead.
    private static func spellIdentifiers(in text: String) -> String {
        replaceMatches(of: #"(?<![\p{L}\d])[a-zA-Z0-9]{6,}(?![\p{L}\d])"#, in: text) {
            match in
            var transitions = 0
            var previousIsDigit: Bool?
            var hasLetter = false
            var hasDigit = false
            for character in match {
                let isDigit = character.isNumber
                hasDigit = hasDigit || isDigit
                hasLetter = hasLetter || !isDigit
                if let previous = previousIsDigit, previous != isDigit {
                    transitions += 1
                }
                previousIsDigit = isDigit
            }
            guard hasLetter, hasDigit, transitions >= 2 else { return match }
            return match.map { character in
                character.isNumber
                    ? EnglishNumberSpeller.spellDigits(String(character))
                    : String(character)
            }.joined(separator: " ")
        }
    }

    private static func replaceMatches(
        of pattern: String,
        in text: String,
        with replacement: (String) -> String
    ) -> String {
        guard
            let regex = try? NSRegularExpression(pattern: pattern)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = ""
        var lastEnd = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else {
                continue
            }
            result += text[lastEnd..<matchRange.lowerBound]
            result += replacement(String(text[matchRange]))
            lastEnd = matchRange.upperBound
        }
        result += text[lastEnd...]
        return result
    }
}
