import Foundation
import Testing

@testable import UnrambleKit

// The cloud realtime path validates a same-connection polish against the raw
// transcript before injecting it, falling back to the transcript when a guard
// fires. These tests pin the composed floor — hallucination, truncation,
// content loss, fabrication, and number substitution — with the number guard
// added so a corrupted amount cannot reach the editor while a faithful
// digitization still passes.
@Suite("Realtime polish validation")
struct RealtimePolishValidationTests {

    private func validate(_ polished: String, raw: String) -> String {
        OpenAIRealtimeSessionDriver.validatedRealtimePolish(
            polished, rawTranscript: raw)
    }

    // MARK: - Number substitution (the new guard)

    @Test("a substituted number falls back to the transcript")
    func numberSubstitutionFallsBack() {
        // Only the number guard catches this: the content words are faithful,
        // but the amount 45,000 became 54,000.
        let raw = "the budget is forty five thousand dollars"
        let polished = "The budget is $54,000."
        #expect(validate(polished, raw: raw) == raw)
    }

    @Test("a faithful number digitization passes")
    func faithfulDigitizationPasses() {
        let raw = "the budget is forty five thousand dollars"
        let polished = "The budget is $45,000."
        #expect(validate(polished, raw: raw) == polished)
    }

    @Test("digitizing a small count passes")
    func smallCountDigitizationPasses() {
        let raw = "we shipped five features this week"
        let polished = "We shipped 5 features this week."
        #expect(validate(polished, raw: raw) == polished)
    }

    // MARK: - Clean polish passes

    @Test("a clean polish with no numbers passes")
    func cleanPolishPasses() {
        let raw = "so basically we should ship the thing tomorrow"
        let polished = "Basically, we should ship the thing tomorrow."
        #expect(validate(polished, raw: raw) == polished)
    }

    @Test("a complete transcript emitted twice falls back")
    func completeTranscriptDuplicatedFallsBack() {
        let raw = "Fix the bug!"
        let polished = "Fix the bug!\n\nFix the bug."
        #expect(validate(polished, raw: raw) == raw)
    }

    @Test("an unchanged transcript with internal repetition passes")
    func internalRepetitionPasses() {
        let raw = "No, no, no, we cannot do that."
        #expect(validate(raw, raw: raw) == raw)
    }

    @Test("repeated phrases already present in the transcript pass")
    func dictatedRepeatedPhrasesPass() {
        let raw = "This is very good, very good work."
        #expect(validate(raw, raw: raw) == raw)
    }

    @Test("an unrequested compact-series list falls back to prose")
    func compactSeriesListFallsBack() {
        let raw = "Grab milk, eggs, a loaf of bread, some coffee, and a couple "
            + "of bananas on the way home."
        let polished = """
            Grab:
            - Milk
            - Eggs
            - A loaf of bread
            - Some coffee
            - A couple of bananas on the way home
            """
        #expect(validate(polished, raw: raw) == raw)
    }

    @Test("a strongly signaled checklist may become a list")
    func signaledChecklistPasses() {
        let raw = "The release checklist is: run the migration, clear the "
            + "cache, restart the workers, and verify the dashboards."
        let polished = """
            The release checklist is:
            - Run the migration
            - Clear the cache
            - Restart the workers
            - Verify the dashboards
            """
        #expect(validate(polished, raw: raw) == polished)
    }

    // MARK: - Existing floor still holds

    @Test("a dropped clause still falls back to the transcript")
    func droppedClauseFallsBack() {
        let raw = "we need to review the security report and update the "
            + "dependencies and then schedule the deploy for friday"
        let polished = "We need to review the security report."
        #expect(validate(polished, raw: raw) == raw)
    }

    @Test("an empty polish falls back to the transcript")
    func emptyPolishFallsBack() {
        let raw = "just a quick note about the meeting"
        #expect(validate("   ", raw: raw) == raw)
    }

    @Test("an empty transcript returns the polish unchanged")
    func emptyTranscriptReturnsPolish() {
        #expect(validate("Anything.", raw: "") == "Anything.")
    }

    // MARK: - Dictated-command round-trip

    // The cloud path converts dictated commands to <keep> tokens before the
    // model and reveals them after. This exercises that round-trip with an
    // identity model: the input step and the output steps finishStreaming runs.
    private func output(_ modelResponse: String) -> String {
        PolishPipeline.normalizeFormatting(
            PolishPipeline.stripKeepTags(
                modelResponse.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test("a dictated paragraph command round-trips to a break")
    func paragraphCommandRoundTrips() {
        let prepared = PolishPipeline.substituteDictatedPunctuation(
            "First part new paragraph second part")
        #expect(prepared.contains("<keep>[PAR]</keep>"))
        let out = output(prepared)  // the model preserved the token
        #expect(out.contains("\n\n"))
        #expect(!out.contains("<keep>"))
        #expect(!out.contains("[PAR]"))
        #expect(!out.lowercased().contains("new paragraph"))
    }

    @Test("a model that also broke the line does not stack blanks")
    func preservedTokenWithModelBreakStaysSingle() {
        // The model kept the token and also rendered its own break.
        let out = output("First part.\n\n<keep>[PAR]</keep>\n\nSecond part.")
        #expect(out == "First part.\n\nSecond part.")
    }

    @Test("talking about a paragraph is not converted")
    func paragraphAsContentNotConverted() {
        let prepared = PolishPipeline.substituteDictatedPunctuation(
            "start a new paragraph after the intro")
        #expect(!prepared.contains("[PAR]"))
        #expect(prepared.contains("new paragraph"))
    }
}
