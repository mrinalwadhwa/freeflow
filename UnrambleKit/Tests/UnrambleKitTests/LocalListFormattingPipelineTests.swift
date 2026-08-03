import Foundation
import Testing

@testable import UnrambleKit

@Suite("Local list formatting")
struct LocalListFormattingPipelineTests {
    @Test("Detects enumerated and lead-in lists with at least three items")
    func detectsCandidates() {
        #expect(LocalListFormattingPipeline.isCandidate(
            "The priorities are first, fix login. Second, add caching. "
                + "Third, write documentation."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "Step 1. Clone the repo. Step 2. Install dependencies. "
                + "Step 3. Run tests."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "Please order five monitors, three keyboards, and ten mice."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "The priorities are first fix login second add caching "
                + "third write documentation"))
        #expect(LocalListFormattingPipeline.isCandidate(
            "My focus areas are one refactor auth two improve errors "
                + "and three add logging"))
        #expect(LocalListFormattingPipeline.isCandidate(
            "Please order five monitors three keyboards and ten mice"))
        #expect(LocalListFormattingPipeline.isCandidate(
            "The tasks for this sprint are first set up CI second write tests "
                + "and third update deployment"))
        #expect(LocalListFormattingPipeline.isCandidate(
            "The release checklist is: run the migration, clear the cache, "
                + "restart the workers, and verify the dashboards."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "I want to lay out a few theories. The first is technical debt. "
                + "The second is slow review. The third is context switching."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "Okay, a bunch of stuff from testing: the search is slow, the "
                + "filters don't persist, the export times out, and errors "
                + "are vague."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "Before launch, we still need to finalize pricing, set up "
                + "monitoring, write the guide, and schedule the emails."))
        #expect(LocalListFormattingPipeline.isCandidate(
            "Here's the launch plan. In the first week, release to a small "
                + "group. In the second week, open it up. In the third week, "
                + "run the ad push."))
    }

    @Test("Leaves two-item phrases and ordinary prose out of Qwen")
    func rejectsNonCandidates() {
        #expect(!LocalListFormattingPipeline.isCandidate(
            "The choices are accept or reject."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "Please review the design and the implementation."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "The server is healthy, the dashboard is clean, and we can ship."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "These work items should use Codex only, because the current "
                + "defaults are expensive, and we should choose another mode."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "The first few items have labels, but the rest are solid boxes, "
                + "and each type receives a color."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "Attach it to number two, one, two, three, four. Is that correct?"))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "I need to buy eggs milk bread butter and cheese."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "Grab milk, eggs, a loaf of bread, some coffee, and a couple of "
                + "bananas on the way home."))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "First the database second the cache third the load balancer"))
        #expect(!LocalListFormattingPipeline.isCandidate(
            "We tried three approaches: the first one worked but was slow, "
                + "the second one had bugs, and the third one shipped."))
    }

    @Test("Bounds the text sent to the list adapter")
    func rejectsLongCandidate() {
        let longPrefix = Array(
            repeating: "ordinary", count:
                LocalListFormattingPipeline.maximumCandidateWords)
            .joined(separator: " ")
        #expect(!LocalListFormattingPipeline.isCandidate(
            longPrefix + " first one second two third three"))
    }

    @Test("Accepts a faithful vertical numbered list")
    func validatesNumberedList() {
        let source = "The priorities are first, fix the login bug. "
            + "Second, add caching. Third, write documentation."
        let formatted = """
            The priorities are:
            1. Fix the login bug
            2. Add caching
            3. Write documentation
            """

        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: formatted))
    }

    @Test("Accepts one faithful list surrounded by unchanged prose")
    func validatesListSurroundedByProse() {
        let source = "The opening paragraph should remain ordinary prose. "
            + "My priorities are first, confirm long recordings. "
            + "Second, protect ordinary sentences. "
            + "Third, format explicit sequences. "
            + "The final sentence should return to ordinary prose."
        let formatted = """
            The opening paragraph should remain ordinary prose.

            My priorities are:
            1. Confirm long recordings
            2. Protect ordinary sentences
            3. Format explicit sequences

            The final sentence should return to ordinary prose.
            """

        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: formatted))
    }

    @Test("Rejects item markers split by intervening prose")
    func rejectsDiscontiguousList() {
        let source = "The priorities are first, fix login. "
            + "Second, add caching. Third, write documentation."
        let formatted = """
            The priorities are:
            1. Fix login
            This prose interrupts the list.
            2. Add caching
            3. Write documentation
            """

        #expect(!LocalListFormattingPipeline.validates(
            source: source, formatted: formatted))
    }

    @Test("Accepts number normalization and a structural final conjunction")
    func validatesBulletedList() {
        let source =
            "Please order five monitors, three keyboards, and ten mice."
        let formatted = """
            Please order:
            - 5 monitors
            - 3 keyboards
            - 10 mice
            """

        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: formatted))
    }

    @Test("Accepts generated numbering for an unordered spoken checklist")
    func validatesGeneratedNumbering() {
        let source = "The release checklist is: run the migration, clear the "
            + "cache, restart the workers, and verify the dashboards."
        let formatted = """
            The release checklist is:
            1. Run the migration
            2. Clear the cache
            3. Restart the workers
            4. Verify the dashboards
            """

        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: formatted))
    }

    @Test("Generated lists require a strong list-intent signal")
    func generatedListRequiresIntent() {
        let compact = "Grab milk, eggs, a loaf of bread, some coffee, and a "
            + "couple of bananas on the way home."
        let compactList = """
            Grab:
            - Milk
            - Eggs
            - A loaf of bread
            - Some coffee
            - A couple of bananas on the way home
            """
        #expect(!LocalListFormattingPipeline.allowsGeneratedList(
            source: compact, formatted: compactList))

        let checklist = "The release checklist is: run the migration, clear "
            + "the cache, restart the workers, and verify the dashboards."
        let checklistList = """
            The release checklist is:
            - Run the migration
            - Clear the cache
            - Restart the workers
            - Verify the dashboards
            """
        #expect(LocalListFormattingPipeline.allowsGeneratedList(
            source: checklist, formatted: checklistList))
        #expect(LocalListFormattingPipeline.allowsGeneratedList(
            source: compact, formatted: compact))
    }

    @Test("Deterministically formats ordinal theories without absorbing conclusion")
    func deterministicallyFormatsOrdinalTheories() {
        let source = "I want to lay out a few theories. The first is technical "
            + "debt. The second is slow review. The third is context switching. "
            + "If I had to choose, I would fix context switching."
        let output = LocalListFormattingPipeline.deterministicFormatIfSafe(
            source)

        #expect(output?.contains("\n1. The first is technical debt.") == true)
        #expect(output?.contains("\n2. The second is slow review.") == true)
        #expect(output?.contains("\n3. The third is context switching.") == true)
        #expect(output?.hasSuffix(
            "If I had to choose, I would fix context switching.") == true)
        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: output ?? ""))
    }

    @Test("Deterministically formats a signaled multi-clause issue report")
    func deterministicallyFormatsIssueReport() {
        let source = "Okay, a bunch of stuff from testing: the search is slow, "
            + "the filters don't persist, the export times out, and the errors "
            + "are vague."
        let output = LocalListFormattingPipeline.deterministicFormatIfSafe(
            source)

        #expect(output?.contains("\n- the search is slow") == true)
        #expect(output?.contains("\n- the filters don't persist") == true)
        #expect(output?.contains("\n- the export times out") == true)
        #expect(output?.contains("\n- the errors are vague.") == true)
        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: output ?? ""))
    }

    @Test("Formats the recorded issue report when STT omits its colon")
    func deterministicallyFormatsIssueReportWithoutColon() {
        let source = "Okay, a bunch of stuff from testing the search is slow. "
            + "The filters don't persist, the export time's out on big data "
            + "sets. The mobile layout breaks on small screens, and the error "
            + "messages are still too vague."
        let output = LocalListFormattingPipeline.deterministicFormatIfSafe(
            source)

        #expect(output?.contains("\n- the search is slow") == true)
        #expect(output?.contains("\n- The filters don't persist") == true)
        #expect(output?.contains("\n- the export time's out on big data sets")
            == true)
        #expect(output?.contains("\n- The mobile layout breaks on small screens")
            == true)
        #expect(output?.contains("\n- the error messages are still too vague.")
            == true)
        #expect(LocalListFormattingPipeline.validates(
            source: source, formatted: output ?? ""))
    }

    @Test("Deterministic formatting ignores compact noun sequences")
    func deterministicFormattingRejectsCompactSeries() {
        #expect(LocalListFormattingPipeline.deterministicFormatIfSafe(
            "Grab milk, eggs, bread, coffee, and bananas on the way home.")
            == nil)
        #expect(LocalListFormattingPipeline.deterministicFormatIfSafe(
            "A bunch of things happened. The database recovered. The team "
                + "met. The release continued.") == nil)
    }

    @Test("Accepts boundaries encoded by unpunctuated ordinals and quantities")
    func validatesUnpunctuatedExplicitLists() {
        #expect(LocalListFormattingPipeline.validates(
            source:
                "The priorities are first fix login second add caching "
                + "third write documentation",
            formatted: """
                The priorities are:
                1. Fix login
                2. Add caching
                3. Write documentation
                """))
        #expect(LocalListFormattingPipeline.validates(
            source: "Please order five monitors three keyboards and ten mice",
            formatted: """
                Please order:
                - 5 monitors
                - 3 keyboards
                - 10 mice
                """))
    }

    @Test("Accepts an already line-separated spoken ordinal list")
    func validatesLineSeparatedOrdinalList() async {
        let source = "Here are the action items. New line. "
            + "First, review the security report. New line second, "
            + "update the dependencies. New line third, schedule the "
            + "deploy for Friday."
        let client = StaticListClient(output: """
            Here are the action items.
            1. Review the security report.
            2. Update the dependencies.
            3. Schedule the deploy for Friday.
            """)

        let accepted = await LocalListFormattingPipeline.formatIfSafe(
            source, chatClient: client, model: "test",
            tone: nil, precedingText: nil)

        #expect(accepted?.contains("\n1. Review the security report") == true)
    }

    @Test("Rejects an item boundary with no source boundary evidence")
    func rejectsInventedBoundary() {
        let source = "The action items are update the road map schedule, "
            + "a design review, and hire two engineers."
        let formatted = """
            The action items are:
            - Update the road map
            - Schedule
            - A design review
            - Hire 2 engineers
            """

        #expect(!LocalListFormattingPipeline.validates(
            source: source, formatted: formatted))
    }

    @Test("Rejects missing, invented, reordered, or inline content")
    func rejectsUnfaithfulOutput() {
        let source = "The priorities are first, fix login. "
            + "Second, add caching. Third, write documentation."

        #expect(!LocalListFormattingPipeline.validates(
            source: source,
            formatted: "The priorities are: 1. Fix login 2. Add caching "
                + "3. Write documentation"))
        #expect(!LocalListFormattingPipeline.validates(
            source: source,
            formatted: """
                The priorities are:
                1. Fix login
                2. Add caching
                3. Write tests
                """))
        #expect(!LocalListFormattingPipeline.validates(
            source: source,
            formatted: """
                The priorities are:
                1. Add caching
                2. Fix login
                3. Write documentation
                """))
    }

    @Test("Returns a safe model list and rejects an unsafe one")
    func formatsOnlyWhenValidated() async {
        let source =
            "Please order five monitors, three keyboards, and ten mice."
        let safe = StaticListClient(output: """
            Please order:
            - 5 monitors
            - 3 keyboards
            - 10 mice
            """)
        let unsafe = StaticListClient(output: """
            Please order:
            - 5 monitors
            - 3 keyboards
            - 10 trackpads
            """)

        let accepted = await LocalListFormattingPipeline.formatIfSafe(
            source, chatClient: safe, model: "test",
            tone: nil, precedingText: nil)
        let rejected = await LocalListFormattingPipeline.formatIfSafe(
            source, chatClient: unsafe, model: "test",
            tone: nil, precedingText: nil)

        #expect(accepted?.contains("\n- 5 monitors") == true)
        #expect(rejected == nil)
    }
}

private struct StaticListClient: PolishChatClient {
    let output: String

    func complete(
        model: String,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        output
    }
}
