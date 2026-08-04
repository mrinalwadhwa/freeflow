import Foundation
import Testing

@testable import UnrambleKit

@Suite("Phrase meta-command interpreter")
struct PhraseMetaCommandInterpreterTests {

    private let interpreter = PhraseMetaCommandInterpreter()

    @Test(
        "Whole-utterance hang-up phrases match",
        arguments: [
            "hang up",
            "Hang up.",
            "  HANG UP!  ",
            "hang  up",
            "Hang up the call.",
            "End the call",
        ])
    func matchesHangUpPhrases(utterance: String) async {
        #expect(await interpreter.interpret(utterance) == .hangUp)
    }

    @Test(
        "Anything beyond the bare phrase stays content",
        arguments: [
            "please hang up",
            "hang up the phone when you are done",
            "we should hang up the call handler here",
            "the server should hang up idle connections",
            "fix the failing resampler test",
            "",
            "   ",
        ])
    func embeddedOrUnrelatedUtterancesStayContent(utterance: String) async {
        #expect(await interpreter.interpret(utterance) == nil)
    }
}
