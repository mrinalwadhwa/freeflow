import Foundation

/// Applies the broader v8 Qwen adapter only to short, strongly signaled lists.
///
/// Cohere remains the source of truth. The formatter accepts a model result
/// only when it is a vertical list, preserves the source tokens in order, and
/// places every item boundary at a boundary already supported by the Cohere
/// transcript. Any uncertainty returns `nil` so the caller can keep Cohere.
enum LocalListFormattingPipeline {
    static let maximumCandidateWords = 160

    private static let strongEnumeratorPatterns = [
        #"\bfirst\b[\s\S]*(?:^|[.!?;]\s+)\bsecond\b[\s\S]*(?:^|[.!?;]\s+)\bthird\b"#,
        #"\bstep\s+(?:1|one)\b[\s\S]*\bstep\s+(?:2|two)\b[\s\S]*\bstep\s+(?:3|three)\b"#,
    ].map {
        try! NSRegularExpression(
            pattern: $0, options: [.caseInsensitive, .anchorsMatchLines])
    }

    private static let ordinalEnumeratorPattern = try! NSRegularExpression(
        pattern: #"\bfirst\b[\s\S]*\bsecond\b[\s\S]*\bthird\b"#,
        options: [.caseInsensitive])

    private static let cardinalEnumeratorPattern = try! NSRegularExpression(
        pattern: #"\b(?:1|one)\b[\s\S]*\b(?:2|two)\b[\s\S]*\b(?:3|three)\b"#,
        options: [.caseInsensitive])

    private static let leadInPatterns = [
        #"\b(?:priorities|action items|focus areas|key takeaways|steps|tasks|items)\s+(?:are|include)\b"#,
        #"\btasks\s+for\s+(?:this|the)\s+\w+\s+(?:are|include)\b"#,
        #"\b(?:i|we)\s+need\s+to\s+(?:buy|get|order|pick\s+up)\b"#,
        #"\bplease\s+(?:buy|get|order)\b"#,
        #"\b(?:picked|picking)\s+up\s+(?:at|from)\b"#,
    ].map {
        try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    private static let quantifiedListLeadInPatterns = [
        #"\b(?:i|we)\s+need\s+to\s+(?:buy|get|order|pick\s+up)\b"#,
        #"\bplease\s+(?:buy|get|order)\b"#,
        #"\b(?:picked|picking)\s+up\s+(?:at|from)\b"#,
    ].map {
        try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?"#)

    private static let itemMarkerPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:[-*•]\s+|(?:step\s+)?(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)[.):]?\s+)"#,
        options: [.caseInsensitive])

    struct Token: Equatable {
        let canonical: String
        let range: Range<String.Index>
    }

    static func isCandidate(_ text: String) -> Bool {
        let wordCount = tokens(in: text).count
        guard wordCount >= 4, wordCount <= maximumCandidateWords else {
            return false
        }

        if strongEnumeratorPatterns.contains(where: {
            hasMatch($0, in: text)
        }) {
            return true
        }

        guard leadInPatterns.contains(where: { hasMatch($0, in: text) })
        else { return false }

        if hasMatch(ordinalEnumeratorPattern, in: text)
            || hasMatch(cardinalEnumeratorPattern, in: text)
        {
            return true
        }

        if quantifiedListLeadInPatterns.contains(where: {
            hasMatch($0, in: text)
        }), quantityCount(in: text) >= 3 {
            return true
        }

        let commas = text.reduce(into: 0) {
            if $1 == "," || $1 == ";" { $0 += 1 }
        }
        let lower = text.lowercased()
        return commas >= 2 && lower.range(
            of: #"\b(?:and|or)\b"#,
            options: .regularExpression) != nil
    }

    static func formatIfSafe(
        _ source: String,
        chatClient: any PolishChatClient,
        model: String,
        tone: String?,
        precedingText: String?
    ) async -> String? {
        let validationSource = PolishPipeline.stripKeepTags(
            PolishPipeline.substituteDictatedPunctuation(
                source,
                casual: tone == "casual",
                precedingText: precedingText),
            casual: tone == "casual")
        guard isCandidate(validationSource) else { return nil }

        let formatted = await PolishPipeline.polish(
            source,
            chatClient: chatClient,
            model: model,
            tone: tone,
            precedingText: precedingText,
            breakMode: .expandBeforeModel,
            maxResamples: 0)

        guard validates(source: validationSource, formatted: formatted) else {
            Log.debug("[LocalListFormatting] rejected model output")
            return nil
        }
        Log.debug("[LocalListFormatting] accepted vertical list")
        return formatted
    }

    static func validates(source: String, formatted: String) -> Bool {
        guard formatted.contains("\n"),
            let items = parsedItems(from: formatted),
            items.count >= 3
        else { return false }

        let sourceTokens = tokens(in: source)
        let outputTokens = tokens(in: formatted)
        guard !sourceTokens.isEmpty, !outputTokens.isEmpty else { return false }

        var sourceCursor = 0
        var itemSpans: [Range<Int>] = []
        for item in items {
            let itemTokens = tokens(in: item).map(\.canonical)
            guard !itemTokens.isEmpty,
                let span = find(
                    itemTokens, in: sourceTokens, startingAt: sourceCursor)
            else { return false }
            if !itemSpans.isEmpty,
                !hasSupportedBoundary(
                    before: sourceTokens[span.lowerBound], in: source,
                    previousToken: sourceTokens[span.lowerBound - 1])
            {
                return false
            }
            itemSpans.append(span)
            sourceCursor = span.upperBound
        }

        let sourceWords = sourceTokens.map(\.canonical)
        let outputWords = outputTokens.map(\.canonical)
        if sourceWords == outputWords { return true }

        // A vertical list conventionally drops the final spoken conjunction.
        // Permit that one omission only when it lies between the penultimate
        // and final aligned items. Every other source token must remain.
        guard itemSpans.count >= 2 else { return false }
        let structuralRange =
            itemSpans[itemSpans.count - 2].upperBound
                ..< itemSpans[itemSpans.count - 1].lowerBound
        for index in structuralRange where sourceWords[index] == "and"
            || sourceWords[index] == "or"
        {
            var withoutConjunction = sourceWords
            withoutConjunction.remove(at: index)
            if withoutConjunction == outputWords { return true }
        }
        return false
    }

    private static func parsedItems(from output: String) -> [String]? {
        let lines = output.split(
            separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var items: [String] = []
        var listFinished = false

        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = itemMarkerPattern.firstMatch(
                in: line, range: nsRange),
                let marker = Range(match.range, in: line)
            {
                guard !listFinished else { return nil }
                let item = line[marker.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !item.isEmpty else { return nil }
                items.append(item)
            } else if !items.isEmpty {
                // Unmarked prose may follow one contiguous list. A later item
                // marker would make the structure ambiguous and is rejected.
                listFinished = true
            }
        }
        return items
    }

    private static func find(
        _ needle: [String],
        in haystack: [Token],
        startingAt start: Int
    ) -> Range<Int>? {
        guard !needle.isEmpty, start < haystack.count,
            needle.count <= haystack.count - start
        else { return nil }

        for index in start...(haystack.count - needle.count) {
            let candidate = haystack[index..<(index + needle.count)]
                .map(\.canonical)
            if candidate == needle {
                return index..<(index + needle.count)
            }
        }
        return nil
    }

    private static func hasSupportedBoundary(
        before token: Token,
        in source: String,
        previousToken: Token
    ) -> Bool {
        let prefix = source[..<token.range.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = prefix.last, ",;:.!?".contains(last) {
            return true
        }
        if previousToken.canonical == "and"
            || previousToken.canonical == "or"
        {
            return true
        }
        if let number = Int(token.canonical), (1...10).contains(number) {
            return true
        }
        return Int(previousToken.canonical).map { (1...10).contains($0) }
            ?? false
    }

    private static func quantityCount(in text: String) -> Int {
        tokens(in: text).count {
            guard let number = Int($0.canonical) else { return false }
            return (1...10).contains(number) || number == 15
        }
    }

    private static func tokens(in text: String) -> [Token] {
        let nsRange = NSRange(text.startIndex..., in: text)
        return wordPattern.matches(in: text, range: nsRange).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return Token(
                canonical: canonical(String(text[range])),
                range: range)
        }
    }

    private static func canonical(_ token: String) -> String {
        let lower = token.lowercased()
            .replacingOccurrences(of: "’", with: "'")
        return [
            "one": "1", "first": "1",
            "two": "2", "second": "2",
            "three": "3", "third": "3",
            "four": "4", "fourth": "4",
            "five": "5", "fifth": "5",
            "six": "6", "sixth": "6",
            "seven": "7", "seventh": "7",
            "eight": "8", "eighth": "8",
            "nine": "9", "ninth": "9",
            "ten": "10", "tenth": "10",
            "fifteen": "15", "fifteenth": "15",
        ][lower] ?? lower
    }

    private static func hasMatch(
        _ regex: NSRegularExpression,
        in text: String
    ) -> Bool {
        regex.firstMatch(
            in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
