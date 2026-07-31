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
