import Foundation
import Testing

@testable import UnrambleKit

@Suite("Mid-clause heuristics")
struct MidClauseHeuristicsTests {

    @Test(
        "Function-word tails read as unfinished thoughts",
        arguments: [
            "we need to make a list of.",
            "less in the shape but more in.",
            "I want to change the",
            "Send it to",
            "It should work AND",
            "let me see how much grace period I have before.",
            "run the tests after.",
            "it will not work unless.",
        ])
    func functionWordTailsAreMidClause(transcript: String) {
        #expect(MidClauseHeuristics.endsMidClause(transcript))
    }

    @Test(
        "Content-word tails and empty text keep ordinary timing",
        arguments: [
            "this is getting good.",
            "Fix the failing resampler test.",
            "hang up",
            "",
            "   ",
        ])
    func contentTailsAndEmptyAreNotMidClause(transcript: String) {
        #expect(!MidClauseHeuristics.endsMidClause(transcript))
    }
}
