import Foundation
import Testing

@testable import UnrambleKit

@Suite("Claude Code transcript locator")
struct ClaudeCodeTranscriptLocatorTests {

    private let workingDirectory = "/Users/dev/Workspace/project"
    private let slugDirectory = "-Users-dev-Workspace-project"

    @Test("Returns the last assistant text of the newest session")
    func returnsLastAssistantText() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [
                TranscriptFixture.claudeAssistant(
                    text: "Earlier answer.", cwd: workingDirectory),
                TranscriptFixture.claudeAssistant(
                    text: "Final answer.",
                    cwd: workingDirectory,
                    timestamp: "2026-08-01T10:05:00.000Z"),
                TranscriptFixture.claudeToolUseAssistant(cwd: workingDirectory),
                TranscriptFixture.claudeUser(text: "thanks"),
            ])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "Final answer.")
        #expect(response?.agentName == "Claude Code")
        #expect(response?.projectName == "project")
        #expect(
            response?.timestamp
                == TranscriptFiles.date(fromISO8601: "2026-08-01T10:05:00.000Z"))
    }

    @Test("Maps dots in the working directory to dashes")
    func mapsDotsToDashes() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "-Users-dev-pro-ject/session.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "Answer.")])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: "/Users/dev/pro.ject")

        #expect(response?.markdown == "Answer.")
    }

    @Test("Accepts a record whose cwd is a subdirectory of the process cwd")
    func acceptsSubdirectoryRecordCwd() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [
                TranscriptFixture.claudeAssistant(
                    text: "From a subdirectory.",
                    cwd: workingDirectory + "/sub/dir")
            ])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "From a subdirectory.")
    }

    @Test("Skips a record whose cwd is unrelated")
    func skipsUnrelatedRecordCwd() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [
                TranscriptFixture.claudeAssistant(
                    text: "Matching.", cwd: workingDirectory),
                TranscriptFixture.claudeAssistant(
                    text: "Unrelated.", cwd: "/somewhere/else"),
            ])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "Matching.")
    }

    @Test("Prefers the newest session file")
    func prefersNewestSessionFile() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/old.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "Old.")],
            modifiedAt: Date(timeIntervalSince1970: 1_000))
        try fixture.writeJSONL(
            at: "\(slugDirectory)/new.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "New.")],
            modifiedAt: Date(timeIntervalSince1970: 2_000))

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "New.")
    }

    @Test("Falls back to an older file when the newest has no response")
    func fallsBackToOlderFile() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/old.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "Old answer.")],
            modifiedAt: Date(timeIntervalSince1970: 1_000))
        try fixture.writeJSONL(
            at: "\(slugDirectory)/new.jsonl",
            records: [TranscriptFixture.claudeUser(text: "just started")],
            modifiedAt: Date(timeIntervalSince1970: 2_000))

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "Old answer.")
    }

    @Test("Tolerates malformed lines")
    func toleratesMalformedLines() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let file = try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "Valid.")])
        let contents = try String(contentsOf: file, encoding: .utf8)
        try (contents + "\nnot json\n{\"broken\": ").write(
            to: file, atomically: true, encoding: .utf8)

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "Valid.")
    }

    @Test("Maps underscores and non-ASCII letters to dashes")
    func mapsUnderscoresAndUnicodeToDashes() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "-Users-dev-my-proj/session.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "Underscore.")])
        try fixture.writeJSONL(
            at: "-Users-dev-caf-/session.jsonl",
            records: [TranscriptFixture.claudeAssistant(text: "Unicode.")])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)

        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: "/Users/dev/my_proj")?.markdown
                == "Underscore.")
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: "/Users/dev/caf\u{00E9}")?.markdown
                == "Unicode.")
    }

    @Test("Falls back to the file's modification time without a timestamp")
    func fallsBackToModificationTime() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        let modified = Date(timeIntervalSince1970: 1_000)
        try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [
                TranscriptFixture.claudeAssistant(
                    text: "Untimestamped.", timestamp: nil)
            ],
            modifiedAt: modified)

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.timestamp == modified)
    }

    @Test("Parses a plain ISO timestamp without fractional seconds")
    func parsesPlainISOTimestamp() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [
                TranscriptFixture.claudeAssistant(
                    text: "Plain.", timestamp: "2026-08-01T10:00:00Z")
            ])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(
            response?.timestamp
                == TranscriptFiles.date(fromISO8601: "2026-08-01T10:00:00Z"))
    }

    @Test("Joins several text parts and drops whitespace-only parts")
    func joinsTextParts() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "\(slugDirectory)/session.jsonl",
            records: [
                TranscriptFixture.claudeAssistant(parts: ["A", "   ", "B"])
            ])

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "A\n\nB")
    }

    @Test("Returns nil when the project has no transcripts")
    func returnsNilWithoutTranscripts() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }

        let locator = ClaudeCodeTranscriptLocator(
            projectsDirectory: fixture.root)
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)
    }
}
