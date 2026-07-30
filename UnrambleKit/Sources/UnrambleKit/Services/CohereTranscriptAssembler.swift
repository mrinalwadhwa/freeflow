import Foundation

/// Conservatively joins transcripts from overlapping Cohere audio windows.
///
/// Content is deleted only when a long suffix/prefix alignment establishes
/// that both windows transcribed the same audio. If alignment is uncertain,
/// both surfaces are retained on separate lines.
struct CohereTranscriptAssembler: Sendable {
    enum Method: String, Equatable, Sendable {
        case emptyLeft
        case emptyRight
        case exactWordOverlap
        case fuzzyWordOverlap
        case unresolvedPreserveBoth
    }

    struct Merge: Equatable, Sendable {
        let text: String
        let method: Method
        let leftOverlapWords: Int
        let rightOverlapWords: Int
        let repairedContinuationPunctuation: Bool
    }

    private struct Lexeme {
        let normalized: String
        let range: NSRange
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"(?i)https?://[^\s]+|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|\d+(?:[.:/]\d+)+|[A-Z0-9]+(?:['’_-][A-Z0-9]+)*"#)

    static func merge(
        _ leftInput: String,
        _ rightInput: String,
        maximumOverlapWords: Int = 32
    ) -> Merge {
        var left = leftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rightInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else {
            return Merge(
                text: right, method: .emptyLeft,
                leftOverlapWords: 0, rightOverlapWords: 0,
                repairedContinuationPunctuation: false)
        }
        guard !right.isEmpty else {
            return Merge(
                text: left, method: .emptyRight,
                leftOverlapWords: 0, rightOverlapWords: 0,
                repairedContinuationPunctuation: false)
        }

        let leftWords = lexemes(in: left)
        let rightWords = lexemes(in: right)
        let maximum = min(
            maximumOverlapWords, leftWords.count, rightWords.count)

        var leftOverlap = 0
        var rightOverlap = 0
        var method = Method.exactWordOverlap
        if maximum >= 2 {
            for count in stride(from: maximum, through: 2, by: -1) {
                let lhs = leftWords.suffix(count).map(\.normalized)
                let rhs = rightWords.prefix(count).map(\.normalized)
                if Array(lhs) == Array(rhs) {
                    leftOverlap = count
                    rightOverlap = count
                    break
                }
            }
        }

        if leftOverlap == 0, maximum >= 4 {
            var best: (
                score: Int, distance: Int,
                leftCount: Int, rightCount: Int
            )?
            for leftCount in 4...maximum {
                let lower = max(4, leftCount - 2)
                let upper = min(maximum, leftCount + 2)
                guard lower <= upper else { continue }
                for rightCount in lower...upper {
                    let lhs = Array(
                        leftWords.suffix(leftCount).map(\.normalized))
                    let rhs = Array(
                        rightWords.prefix(rightCount).map(\.normalized))
                    let distance = editDistance(lhs, rhs)
                    let width = max(leftCount, rightCount)
                    guard distance <= 2,
                        distance <= 1 || width >= 8
                    else { continue }
                    let candidate = (
                        min(leftCount, rightCount), distance,
                        leftCount, rightCount)
                    if let current = best {
                        if candidate.0 > current.score
                            || (candidate.0 == current.score
                                && candidate.1 < current.distance)
                        {
                            best = candidate
                        }
                    } else {
                        best = candidate
                    }
                }
            }
            if let best {
                leftOverlap = best.leftCount
                rightOverlap = best.rightCount
                method = .fuzzyWordOverlap
            }
        }

        guard leftOverlap > 0 else {
            return Merge(
                text: left + "\n" + right,
                method: .unresolvedPreserveBoth,
                leftOverlapWords: 0, rightOverlapWords: 0,
                repairedContinuationPunctuation: false)
        }

        if method == .fuzzyWordOverlap {
            let leftNSString = left as NSString
            let overlapStart =
                leftWords[leftWords.count - leftOverlap].range.location
            let prefix = leftNSString.substring(to: overlapStart)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = continuationSurface(
                right, after: prefix)
            return Merge(
                text: prefix.isEmpty
                    ? replacement
                    : prefix + " " + replacement,
                method: method,
                leftOverlapWords: leftOverlap,
                rightOverlapWords: rightOverlap,
                repairedContinuationPunctuation:
                    shouldRepairReplacedOverlap(prefix: prefix, right: right))
        }

        var repaired = false
        if shouldRepairContinuationPunctuation(
            left: left, leftWords: leftWords,
            right: right, rightWords: rightWords,
            rightOverlap: rightOverlap)
        {
            left = stripLastSentenceTerminator(left)
            repaired = true
        }

        let rightNSString = right as NSString
        let cut = rightWords[rightOverlap - 1].range.upperBound
        var suffix = rightNSString.substring(from: cut)
        suffix = suffix.replacingOccurrences(
            of: #"^[\s,.;:!?—-]+"#, with: "",
            options: .regularExpression)
        return Merge(
            text: suffix.isEmpty ? left : left + " " + suffix,
            method: method,
            leftOverlapWords: leftOverlap,
            rightOverlapWords: rightOverlap,
            repairedContinuationPunctuation: repaired)
    }

    /// Prefix safe to expose before the next overlapping window arrives.
    static func stablePrefix(
        of text: String,
        holdingBackWords: Int = 40
    ) -> String {
        let words = lexemes(in: text)
        guard words.count > holdingBackWords else { return "" }
        let ns = text as NSString
        let cut = words[words.count - holdingBackWords].range.location
        return ns.substring(to: cut)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lexemes(in text: String) -> [Lexeme] {
        let ns = text as NSString
        return wordPattern.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        ).map {
            Lexeme(
                normalized: ns.substring(with: $0.range)
                    .lowercased()
                    .replacingOccurrences(of: "’", with: "'"),
                range: $0.range)
        }
    }

    private static func shouldRepairContinuationPunctuation(
        left: String,
        leftWords: [Lexeme],
        right: String,
        rightWords: [Lexeme],
        rightOverlap: Int
    ) -> Bool {
        guard let lastLeftWord = leftWords.last,
            rightOverlap < rightWords.count
        else { return false }
        let leftNS = left as NSString
        let leftTail = leftNS.substring(from: lastLeftWord.range.upperBound)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard leftTail.range(
            of: #"[.!?][\"'”’)]*$"#,
            options: .regularExpression) != nil
        else { return false }

        let rightNS = right as NSString
        let overlapEnd = rightWords[rightOverlap - 1].range.upperBound
        let nextWord = rightWords[rightOverlap]
        let between = rightNS.substring(
            with: NSRange(
                location: overlapEnd,
                length: nextWord.range.location - overlapEnd))
        guard between.range(
            of: #"[.!?]"#, options: .regularExpression) == nil
        else { return false }
        let surface = rightNS.substring(with: nextWord.range)
        return surface.first?.isLowercase == true
    }

    private static func stripLastSentenceTerminator(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"[.!?](?=[\"'”’)]*\s*$)"#,
            with: "", options: .regularExpression)
    }

    private static func continuationSurface(
        _ right: String, after prefix: String
    ) -> String {
        guard !prefix.isEmpty,
            prefix.range(
                of: #"[.!?][\"'”’)]*$"#,
                options: .regularExpression) == nil,
            let first = right.first, first.isUppercase
        else { return right }
        return first.lowercased() + right.dropFirst()
    }

    private static func shouldRepairReplacedOverlap(
        prefix: String, right: String
    ) -> Bool {
        guard !prefix.isEmpty else { return false }
        return prefix.range(
            of: #"[.!?][\"'”’)]*$"#,
            options: .regularExpression) != nil
            && right.first?.isLowercase == true
    }

    private static func editDistance(
        _ left: [String], _ right: [String]
    ) -> Int {
        var row = Array(0...right.count)
        for (leftIndex, leftWord) in left.enumerated() {
            var next = [leftIndex + 1]
            for (rightIndex, rightWord) in right.enumerated() {
                next.append(min(
                    row[rightIndex + 1] + 1,
                    next[rightIndex] + 1,
                    row[rightIndex] + (leftWord == rightWord ? 0 : 1)))
            }
            row = next
        }
        return row[right.count]
    }
}

private extension NSRange {
    var upperBound: Int { location + length }
}
