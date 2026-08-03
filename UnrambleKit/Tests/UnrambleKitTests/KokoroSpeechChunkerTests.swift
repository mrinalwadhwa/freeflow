import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro speech chunker")
struct KokoroSpeechChunkerTests {

    @Test("A short script stays in one chunk")
    func shortScriptStaysWhole() {
        let chunks = KokoroSpeechChunker.chunks(
            from: "The build finished. All tests passed.")
        #expect(chunks == ["The build finished. All tests passed."])
    }

    @Test("Sentences pack into chunks up to the limit")
    func sentencesPackUpToLimit() {
        let chunks = KokoroSpeechChunker.chunks(
            from: "One two three. Four five six. Seven eight nine.",
            maximumLength: 32)
        #expect(chunks == [
            "One two three. Four five six.",
            "Seven eight nine.",
        ])
    }

    @Test("Chunks break at sentence boundaries, not mid-sentence")
    func breaksAtSentenceBoundaries(){
        let chunks = KokoroSpeechChunker.chunks(
            from: "A very long opening sentence here. Short tail.",
            maximumLength: 40)
        #expect(chunks == [
            "A very long opening sentence here.",
            "Short tail.",
        ])
    }

    @Test("An overlong sentence splits at word boundaries")
    func overlongSentenceSplitsAtWords() {
        let chunks = KokoroSpeechChunker.chunks(
            from: "alpha beta gamma delta epsilon",
            maximumLength: 12)
        #expect(chunks == ["alpha beta", "gamma delta", "epsilon"])
    }

    @Test("Decimals and dotted names do not end sentences")
    func decimalsStayWhole() {
        let chunks = KokoroSpeechChunker.chunks(
            from: "Version 2.5 shipped to unramble.app today. Enjoy.")
        #expect(chunks == ["Version 2.5 shipped to unramble.app today. Enjoy."])
    }

    @Test("Line breaks separate sentences")
    func lineBreaksSeparate() {
        let chunks = KokoroSpeechChunker.chunks(
            from: "First line\nSecond line",
            maximumLength: 11)
        #expect(chunks == ["First line", "Second line"])
    }

    @Test("Whitespace-only input yields no chunks")
    func whitespaceYieldsNothing() {
        #expect(KokoroSpeechChunker.chunks(from: "  \n  ").isEmpty)
    }

    @Test("Questions and exclamations end sentences")
    func questionsAndExclamationsEnd() {
        let chunks = KokoroSpeechChunker.chunks(
            from: "Ready? Go! Done.",
            maximumLength: 9)
        #expect(chunks == ["Ready?", "Go! Done."])
    }
}
