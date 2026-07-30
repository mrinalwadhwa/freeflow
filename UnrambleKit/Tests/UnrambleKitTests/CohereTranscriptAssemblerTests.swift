import Testing

@testable import UnrambleKit

@Suite("Cohere rolling transcript assembly")
struct CohereTranscriptAssemblerTests {
    @Test("Exact overlap is removed without losing either side")
    func exactOverlap() {
        let result = CohereTranscriptAssembler.merge(
            "We should draw the arrows going in on the left.",
            "the arrows going in on the left and coming out on the right.")

        #expect(result.text == """
            We should draw the arrows going in on the left \
            and coming out on the right.
            """)
        #expect(result.method == .exactWordOverlap)
        #expect(result.repairedContinuationPunctuation)
    }

    @Test("A high-confidence ASR substitution uses fuzzy overlap")
    func fuzzyOverlap() {
        let result = CohereTranscriptAssembler.merge(
            "The human cue is being populated by",
            "The human queue is being populated by agents and other systems.")

        #expect(result.text == """
            The human queue is being populated by agents and other systems.
            """)
        #expect(result.method == .fuzzyWordOverlap)
    }

    @Test("A newer fuzzy overlap replaces an extra trailing hallucination")
    func fuzzyOverlapReplacesTrailingHallucination() {
        let result = CohereTranscriptAssembler.merge(
            """
            What's happening is the human cue is being populated by agents \
            that consume the agent cue, but also agents.
            """,
            """
            Agents that consume the agent queue, but also other systems. \
            So we should show those other inflows.
            """)

        #expect(result.text == """
            What's happening is the human cue is being populated by agents \
            that consume the agent queue, but also other systems. \
            So we should show those other inflows.
            """)
        #expect(result.method == .fuzzyWordOverlap)
    }

    @Test("Unrelated windows fail open and preserve both")
    func unresolvedPreservesBoth() {
        let result = CohereTranscriptAssembler.merge(
            "The first idea ends here.",
            "A different sentence begins over there.")

        #expect(result.text == """
            The first idea ends here.
            A different sentence begins over there.
            """)
        #expect(result.method == .unresolvedPreserveBoth)
    }

    @Test("A false period at an overlap seam is removed")
    func repairsContinuationPunctuation() {
        let result = CohereTranscriptAssembler.merge(
            "We label them.",
            "We label them inside this vertical rectangle.")

        #expect(result.text == """
            We label them inside this vertical rectangle.
            """)
        #expect(result.repairedContinuationPunctuation)
    }

    @Test("A repeated sentence boundary is retained")
    func retainsConfirmedSentenceBoundary() {
        let result = CohereTranscriptAssembler.merge(
            "We label them.",
            "We label them. Inside this vertical rectangle, we add notes.")

        #expect(result.text == """
            We label them. Inside this vertical rectangle, we add notes.
            """)
        #expect(!result.repairedContinuationPunctuation)
    }

    @Test("Stable prefix withholds the words the next seam may revise")
    func stablePrefixHoldsBackTail() {
        let words = (1...50).map { "word\($0)" }.joined(separator: " ")
        let prefix = CohereTranscriptAssembler.stablePrefix(
            of: words, holdingBackWords: 10)

        #expect(prefix.hasSuffix("word40"))
        #expect(!prefix.contains("word41"))
        #expect(words.hasPrefix(prefix))
    }
}
