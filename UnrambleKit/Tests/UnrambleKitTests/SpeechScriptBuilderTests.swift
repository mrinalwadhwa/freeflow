import Testing

@testable import UnrambleKit

@Suite("Speech script builder")
struct SpeechScriptBuilderTests {

    private let builder = SpeechScriptBuilder()

    @Test("Attribution and title are spoken first")
    func attributionAndTitleComeFirst() {
        let content = ReadableContent(
            attribution: "Claude Code in unramble",
            title: "Fix the resampler",
            segments: [.init(kind: .prose, text: "Done.")])
        #expect(
            builder.script(for: content)
                == "Claude Code in unramble.\nFix the resampler.\nDone.")
    }

    @Test("UI glyphs are spoken as words")
    func glyphsAreSpokenAsWords() {
        let content = ReadableContent(segments: [
            .init(
                kind: .prose,
                text: "Press ✕ to end, ✓ to send, or ■ to stop.")
        ])
        #expect(
            builder.script(for: content)
                == "Press x to end, checkmark to send, or square to stop.")
    }

    @Test("Key symbols read as key names")
    func keySymbolsReadAsKeyNames() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "Press ⌃⇧C to start a call.")
        ])
        #expect(
            builder.script(for: content)
                == "Press control-shift-C to start a call.")
    }

    @Test("Parenthesized single letters read as spelled option labels")
    func parenthesizedLettersReadAsOptions() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "(a) Blue dot, or reply with (b).")
        ])
        #expect(
            builder.script(for: content)
                == "option ay, Blue dot, or reply with option bee.")
    }

    @Test("Commit hashes are spelled character by character")
    func hashesAreSpelledOut() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "Committed as adb6bef3.")
        ])
        #expect(
            builder.script(for: content)
                == "Committed as ay-dee-bee-6-bee-ee-eff-3.")
    }

    @Test("Ordinary words and plain numbers are not spelled")
    func wordsAndNumbersAreNotSpelled() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "The defaced facade cost 12345678.")
        ])
        #expect(
            builder.script(for: content)
                == "The defaced facade cost 12345678.")
    }

    @Test("The caption separator reads as a pause")
    func middleDotSeparatorReadsAsPause() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "Claude · unramble")
        ])
        #expect(builder.script(for: content) == "Claude, unramble")
    }

    @Test("Code blocks are announced by size, not read")
    func codeBlocksAreAnnounced() {
        let content = ReadableContent(segments: [
            .init(kind: .prose, text: "Here is the change."),
            .init(kind: .code, text: "let a = 1\nlet b = 2\nlet c = 3"),
        ])
        #expect(
            builder.script(for: content)
                == "Here is the change.\nCode block, 3 lines, skipped.")
    }

    @Test("A single code line is announced in the singular")
    func singleCodeLineIsSingular() {
        let content = ReadableContent(segments: [
            .init(kind: .code, text: "let a = 1")
        ])
        #expect(builder.script(for: content) == "Command skipped.")
    }

    @Test("Headings end with a period for a spoken pause")
    func headingsGainPeriod() {
        let content = ReadableContent(segments: [
            .init(kind: .heading, text: "What changed"),
            .init(kind: .listItem, text: "the resampler"),
        ])
        #expect(builder.script(for: content) == "What changed.\nthe resampler")
    }

    @Test("Empty content yields an empty script")
    func emptyContentYieldsEmptyScript() {
        #expect(builder.script(for: ReadableContent(segments: [])) == "")
    }
}
