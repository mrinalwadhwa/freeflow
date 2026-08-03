import Foundation

/// Spell numbers as English words for the speech script.
///
/// The phonemizer's own number expansion drops the tens from 21–29 and
/// misreads years, so digits never reach it: the normalizer converts
/// every standalone number to words first. Four-digit values in the
/// year range read as date pairs ("2026" as "twenty twenty six");
/// everything else reads as a cardinal, and runs too long for a
/// cardinal read digit by digit.
enum EnglishNumberSpeller {

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
        "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]

    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety",
    ]

    /// Spell a run of digits as it should be spoken: a year as pairs, a
    /// cardinal when it fits one, digits one by one when it does not.
    static func spellToken(_ digits: String) -> String {
        guard let value = Int(digits), digits.count <= 6 else {
            return spellDigits(digits)
        }
        if digits.count == 4, (1100...2999).contains(value) {
            return spellYear(value)
        }
        // A leading zero reads as dialed digits ("07"), not a cardinal.
        if digits.count > 1, digits.hasPrefix("0") {
            return spellDigits(digits)
        }
        return cardinal(value)
    }

    /// Spell each digit by name ("86" as "eight six").
    static func spellDigits(_ digits: String) -> String {
        digits.compactMap { $0.wholeNumberValue.map { ones[$0] } }
            .joined(separator: " ")
    }

    static func cardinal(_ value: Int) -> String {
        precondition((0...999_999).contains(value))
        if value < 20 {
            return ones[value]
        }
        if value < 100 {
            let remainder = value % 10
            return remainder == 0
                ? tens[value / 10]
                : "\(tens[value / 10]) \(ones[remainder])"
        }
        if value < 1000 {
            let remainder = value % 100
            let hundreds = "\(ones[value / 100]) hundred"
            return remainder == 0
                ? hundreds
                : "\(hundreds) \(cardinal(remainder))"
        }
        let remainder = value % 1000
        let thousands = "\(cardinal(value / 1000)) thousand"
        return remainder == 0
            ? thousands
            : "\(thousands) \(cardinal(remainder))"
    }

    static func ordinal(_ value: Int) -> String {
        let irregulars: [String: String] = [
            "one": "first", "two": "second", "three": "third",
            "five": "fifth", "eight": "eighth", "nine": "ninth",
            "twelve": "twelfth",
        ]
        var words = cardinal(value).split(separator: " ").map(String.init)
        guard let last = words.last else { return "" }
        if let irregular = irregulars[last] {
            words[words.count - 1] = irregular
        } else if last.hasSuffix("y") {
            words[words.count - 1] = String(last.dropLast()) + "ieth"
        } else {
            words[words.count - 1] = last + "th"
        }
        return words.joined(separator: " ")
    }

    private static func spellYear(_ value: Int) -> String {
        if (2000...2009).contains(value) {
            return value == 2000
                ? "two thousand"
                : "two thousand \(ones[value % 100])"
        }
        let high = value / 100
        let low = value % 100
        if low == 0 {
            return "\(cardinal(high)) hundred"
        }
        if low < 10 {
            return "\(cardinal(high)) oh \(ones[low])"
        }
        return "\(cardinal(high)) \(cardinal(low))"
    }
}
