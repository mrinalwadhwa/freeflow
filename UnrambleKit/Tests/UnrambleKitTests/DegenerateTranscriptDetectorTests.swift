import Foundation
import Testing

@testable import UnrambleKit

@Suite("Degenerate transcript detector")
struct DegenerateTranscriptDetectorTests {

    @Test("A recognizer's hallucination loop is degenerate")
    func hallucinationLoopIsDegenerate() {
        let flood = """
            I'm going to go to the next slide. The only thing that \
            I've ever heard about is that I've never heard about the \
            people who are not in the world. I've never heard about \
            the people who are not in the world. I'm not sure if I'm \
            going to be able to do it. I'm not sure if I'm going to \
            be able to do it. I'm not sure if I'm going to be able \
            to do it. I've never heard about the people who are not \
            in the world. I'm going to go to the next slide.
            """
        #expect(DegenerateTranscriptDetector.isDegenerate(flood))
    }

    @Test("Ordinary multi-sentence speech is not degenerate")
    func ordinarySpeechIsNotDegenerate() {
        let turn = """
            Run the failing resampler test again and show me the \
            output. If it still fails, check whether the fixture \
            changed. I think the sample rate constant moved last \
            week. Let me know what you find before changing code.
            """
        #expect(!DegenerateTranscriptDetector.isDegenerate(turn))
    }

    @Test("Repeated short interjections are how people talk")
    func shortInterjectionsAreNotDegenerate() {
        #expect(
            !DegenerateTranscriptDetector.isDegenerate(
                "Yes. Yes. Yes. Yes. Yes. Do it now."))
    }

    @Test("A few sentences cannot form a loop")
    func tooFewSentencesAreNotDegenerate() {
        let twice = "Please run the whole test suite now. "
            + "Please run the whole test suite now."
        #expect(!DegenerateTranscriptDetector.isDegenerate(twice))
    }

    @Test("One repeat among distinct sentences is emphasis, not a loop")
    func singleRepeatIsNotDegenerate() {
        let turn = """
            Undo the last change to the resampler. Undo the last \
            change to the resampler. Then run the focused suite and \
            paste the failure output. Keep the fixtures untouched \
            while you do it.
            """
        #expect(!DegenerateTranscriptDetector.isDegenerate(turn))
    }

    @Test("An utterance of one sentence repeated is a loop")
    func fullyRepeatedSentenceIsDegenerate() {
        let loop = Array(
            repeating: "I'm going to go to the next slide.", count: 5
        ).joined(separator: " ")
        #expect(DegenerateTranscriptDetector.isDegenerate(loop))
    }

    @Test("Punctuation and case differences do not hide a loop")
    func normalizationSeesThroughPunctuation() {
        let loop = """
            it was the best of times, it seems! It was the best of \
            times it seems. IT WAS THE BEST OF TIMES, IT SEEMS. it \
            was the best of times it seems?
            """
        #expect(DegenerateTranscriptDetector.isDegenerate(loop))
    }
}
