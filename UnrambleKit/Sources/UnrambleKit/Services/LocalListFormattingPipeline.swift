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
        #"\b(?:release\s+)?checklist\s+is\b"#,
        #"\b(?:lay\s+out|share)\s+(?:a\s+)?few\s+(?:theories|reasons|options)\b"#,
        #"\ba\s+bunch\s+of\s+(?:stuff|things|issues|problems)(?:\s+from\s+[^.!?:,]+)?\b"#,
        #"\bbefore\s+[^.!?]{1,80}\bwe\s+(?:still\s+)?need\s+to\b"#,
        #"\b(?:launch|release|rollout)\s+plan\b"#,
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

    private static let ordinalSentenceListPattern = try! NSRegularExpression(
        pattern: #"^(.*?)(\bthe\s+first\b.*?[.!?])\s+(\bthe\s+second\b.*?[.!?])\s+(\bthe\s+third\b.*?[.!?])(?:\s+(.*))?$"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static let issueReportLeadInPattern = try! NSRegularExpression(
        pattern: #"\ba\s+bunch\s+of\s+(?:stuff|things|issues|problems)\s+from\s+[\p{L}\p{N}'-]+\b"#,
        options: [.caseInsensitive])

    private static let issueClauseSeparatorPattern = try! NSRegularExpression(
        pattern: #"[,;.!?]\s+(?:and\s+)?(?=the\b)"#,
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

        if let deterministic = deterministicFormatIfSafe(validationSource) {
            Log.debug("[LocalListFormatting] accepted deterministic list")
            return deterministic
        }

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

    /// Format only two exceptionally strong structures without asking the
    /// model to reinterpret them. The final validator still proves lexical
    /// preservation, source order, and boundary support before either result
    /// is returned.
    static func deterministicFormatIfSafe(_ source: String) -> String? {
        guard isCandidate(source) else { return nil }
        let candidates = [
            formatOrdinalSentenceList(source),
            formatIssueReport(source),
        ]
        return candidates.compactMap { $0 }.first {
            validates(source: source, formatted: $0)
        }
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
        let semanticOutputWords = tokens(
            in: strippingItemMarkers(from: formatted)).map(\.canonical)
        let outputCandidates = [outputWords, semanticOutputWords]
        if outputCandidates.contains(sourceWords) { return true }

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
            if outputCandidates.contains(withoutConjunction) { return true }
        }
        return false
    }

    /// Cloud may polish more broadly than Local, but it must not manufacture a
    /// vertical list when the transcript has no strong list-intent signal.
    static func allowsGeneratedList(source: String, formatted: String) -> Bool {
        guard let items = parsedItems(from: formatted), items.count >= 3
        else { return true }
        return isCandidate(source)
    }

    /// List markers are presentation, not dictated content. Compare both the
    /// literal formatted text and a marker-free form so an unordered spoken
    /// checklist may safely use either bullets or generated numbering.
    private static func strippingItemMarkers(from output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let value = String(line)
                let nsRange = NSRange(value.startIndex..., in: value)
                guard let match = itemMarkerPattern.firstMatch(
                    in: value, range: nsRange),
                    let marker = Range(match.range, in: value)
                else { return value }
                return String(value[marker.upperBound...])
            }
            .joined(separator: "\n")
    }

    private static func formatOrdinalSentenceList(_ source: String) -> String? {
        let fullRange = NSRange(source.startIndex..., in: source)
        guard let match = ordinalSentenceListPattern.firstMatch(
            in: source, range: fullRange)
        else { return nil }

        func capture(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                let range = Range(match.range(at: index), in: source)
            else { return nil }
            let value = source[range].trimmingCharacters(
                in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        guard let first = capture(2), let second = capture(3),
            let third = capture(4)
        else { return nil }

        var blocks: [String] = []
        if let prefix = capture(1) { blocks.append(prefix) }
        blocks.append("1. \(first)\n2. \(second)\n3. \(third)")
        if let suffix = capture(5) { blocks.append(suffix) }
        return blocks.joined(separator: "\n\n")
    }

    private static func formatIssueReport(_ source: String) -> String? {
        let fullRange = NSRange(source.startIndex..., in: source)
        guard let leadIn = issueReportLeadInPattern.firstMatch(
            in: source, range: fullRange),
            let leadRange = Range(leadIn.range, in: source)
        else { return nil }

        var bodyStart = leadRange.upperBound
        while bodyStart < source.endIndex,
            source[bodyStart].isWhitespace || ":,;-".contains(source[bodyStart])
        {
            bodyStart = source.index(after: bodyStart)
        }
        guard bodyStart < source.endIndex else { return nil }

        let body = String(source[bodyStart...])
        guard body.lowercased().hasPrefix("the ") else { return nil }
        let bodyRange = NSRange(body.startIndex..., in: body)
        let separators = issueClauseSeparatorPattern.matches(
            in: body, range: bodyRange)
        guard separators.count >= 2 else { return nil }

        var items: [String] = []
        var cursor = body.startIndex
        for separator in separators {
            guard let range = Range(separator.range, in: body) else {
                return nil
            }
            let item = body[cursor..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty else { return nil }
            items.append(item)
            cursor = range.upperBound
        }
        let finalItem = body[cursor...].trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !finalItem.isEmpty else { return nil }
        items.append(finalItem)

        let prefix = source[..<leadRange.upperBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let list = items.map { "- \($0)" }.joined(separator: "\n")
        return "\(prefix):\n\(list)"
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
