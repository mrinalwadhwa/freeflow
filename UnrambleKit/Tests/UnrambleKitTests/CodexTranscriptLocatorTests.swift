import Foundation
import Testing

@testable import UnrambleKit

@Suite("Codex transcript locator")
struct CodexTranscriptLocatorTests {

    private let workingDirectory = "/Users/dev/Workspace/project"

    @Test("Returns the last assistant message of a matching session")
    func returnsLastAssistantMessage() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-a.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexAssistant(text: "First."),
                TranscriptFixture.codexEvent(),
                TranscriptFixture.codexAssistant(
                    text: "Latest.",
                    timestamp: "2026-08-01T10:09:00.000Z"),
            ])

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "Latest.")
        #expect(response?.agentName == "Codex")
        #expect(response?.projectName == "project")
    }

    @Test("Filters out subagent rollouts by thread source")
    func filtersSubagentThreadSource() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-sub.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(
                    cwd: workingDirectory, threadSource: "subagent"),
                TranscriptFixture.codexAssistant(
                    text: "{\"verdict\":\"allow\"}"),
            ])

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)
    }

    @Test("Filters out rollouts whose source names a subagent")
    func filtersSubagentSource() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-sub.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(
                    cwd: workingDirectory, subagentSource: true),
                TranscriptFixture.codexAssistant(text: "internal"),
            ])

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)
    }

    @Test("Skips sessions in other working directories")
    func skipsOtherWorkingDirectories() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-other.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: "/somewhere/else"),
                TranscriptFixture.codexAssistant(text: "Other project."),
            ])

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)
    }

    @Test("Prefers the newest matching rollout")
    func prefersNewestRollout() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/07/31/rollout-old.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexAssistant(text: "Old."),
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_000))
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-new.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexAssistant(text: "New."),
            ],
            modifiedAt: Date(timeIntervalSince1970: 2_000))

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "New.")
    }

    @Test("Considers only the newest rollouts within the candidate limit")
    func candidateLimitCapsSearch() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/07/31/rollout-match.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexAssistant(text: "Old match."),
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_000))
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-other.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: "/somewhere/else"),
                TranscriptFixture.codexAssistant(text: "Other."),
            ],
            modifiedAt: Date(timeIntervalSince1970: 2_000))

        let capped = CodexTranscriptLocator(
            sessionsDirectory: fixture.root, candidateLimit: 1)
        #expect(
            try capped.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)

        let uncapped = CodexTranscriptLocator(
            sessionsDirectory: fixture.root, candidateLimit: 2)
        #expect(
            try uncapped.latestResponse(
                forProcessWorkingDirectory: workingDirectory)?.markdown
                == "Old match.")
    }

    @Test("Falls back to an older rollout when the newest has no response")
    func fallsBackToOlderRollout() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/07/31/rollout-old.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexAssistant(text: "Old answer."),
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_000))
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-new.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexEvent(),
            ],
            modifiedAt: Date(timeIntervalSince1970: 2_000))

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory)?.markdown
                == "Old answer.")
    }

    @Test("Joins several text parts and drops whitespace-only parts")
    func joinsTextParts() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-parts.jsonl",
            records: [
                TranscriptFixture.codexSessionMeta(cwd: workingDirectory),
                TranscriptFixture.codexAssistant(
                    parts: ["A", "   ", "B"], timestamp: nil),
            ],
            modifiedAt: Date(timeIntervalSince1970: 1_000))

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        let response = try locator.latestResponse(
            forProcessWorkingDirectory: workingDirectory)

        #expect(response?.markdown == "A\n\nB")
        #expect(response?.timestamp == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Skips a file whose first record is not session metadata")
    func skipsFileWithoutSessionMeta() throws {
        let fixture = try TranscriptFixture()
        defer { fixture.remove() }
        try fixture.writeJSONL(
            at: "2026/08/01/rollout-broken.jsonl",
            records: [TranscriptFixture.codexAssistant(text: "No meta.")])

        let locator = CodexTranscriptLocator(sessionsDirectory: fixture.root)
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)
    }

    @Test("Returns nil when the sessions directory is missing")
    func returnsNilWithoutSessionsDirectory() throws {
        let locator = CodexTranscriptLocator(
            sessionsDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID())"))
        #expect(
            try locator.latestResponse(
                forProcessWorkingDirectory: workingDirectory) == nil)
    }
}
