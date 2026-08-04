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
        #expect(builder.script(for: content) == "What changed.\nthe resampler.")
    }

    @Test("Empty content yields an empty script")
    func emptyContentYieldsEmptyScript() {
        #expect(builder.script(for: ReadableContent(segments: [])) == "")
    }
}

@Suite("Agent text speech shaping")
struct AgentTextSpeechShapingTests {

    @Test("A markdown link speaks its label, not its URL")
    func linkSpeaksLabel() {
        let spoken = SpeechScriptBuilder.normalizeForSpeech(
            "The draft is ready: [brief.md](/Users/m/Workspace/f/.fluent/drafts/x/brief.md).")
        #expect(spoken.contains("brief dot em-dee"))
        #expect(!spoken.contains("/Users"))
        #expect(!spoken.contains("drafts"))
    }

    @Test("A path collapses to its last component with a line reference")
    func pathCollapsesToLastComponent() {
        let spoken = SpeechScriptBuilder.normalizeForSpeech(
            "Today's dashboard is /Users/m/Workspace/factory/main/src/dashboard.rs:21 basically.")
        #expect(spoken.contains("dashboard dot arr-ess, line 21"))
        #expect(!spoken.contains("/Users"))
        #expect(!spoken.contains("Workspace"))
    }

    @Test("A short file extension spells out as letters")
    func extensionSpellsOut() {
        let spoken = SpeechScriptBuilder.normalizeForSpeech(
            "Open document.rs and notes.md now.")
        #expect(spoken.contains("document dot arr-ess"))
        #expect(spoken.contains("notes dot em-dee"))
    }

    @Test("Decimal numbers and abbreviations stay intact")
    func numbersAndAbbreviationsUntouched() {
        let spoken = SpeechScriptBuilder.normalizeForSpeech(
            "Version 0.1.5 works, e.g. the build.")
        #expect(spoken.contains("0.1.5"))
        #expect(spoken.contains("e.g."))
    }

    @Test("List items end with a sentence break")
    func listItemsGetSentenceBreaks() {
        let content = ReadableContent(segments: [
            .init(kind: .listItem, text: "run-tab selection"),
            .init(kind: .listItem, text: "polling cadence"),
        ])
        let script = SpeechScriptBuilder().script(for: content)
        #expect(script.contains("run-tab selection."))
        #expect(script.contains("polling cadence."))
    }
}
