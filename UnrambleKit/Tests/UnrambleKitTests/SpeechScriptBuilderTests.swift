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
