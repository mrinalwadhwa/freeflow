import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Transcript response watcher")
struct ResponseWatcherTests {

    private func agentSession(
        workingDirectory: String = "/tmp/project"
    ) -> ResolvedAgentSession {
        ResolvedAgentSession(
            agentName: "claude",
            workingDirectory: workingDirectory,
            ttyDevice: nil)
    }

    private func makeLocator() -> StubAgentTranscriptLocator {
        StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"])
    }

    private func makeWatcher(
        locator: StubAgentTranscriptLocator,
        extendedWindow: TimeInterval = 0.4,
        quiescenceWindow: TimeInterval = 0.06,
        narrates: Bool = false
    ) -> TranscriptResponseWatcher {
        TranscriptResponseWatcher(
            locators: [locator],
            quiescenceWindow: quiescenceWindow,
            extendedWindow: extendedWindow,
            pollInterval: 0.01,
            interimParseInterval: 0.01,
            narratesInterimMessages: { narrates })
    }

    private func makeTranscriptFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString).jsonl")
        try Data("record\n".utf8).write(to: file)
        return file
    }

    private func freshResponse(_ markdown: String) -> AgentTranscriptResponse {
        AgentTranscriptResponse(
            agentName: "Claude Code",
            projectName: "project",
            timestamp: Date().addingTimeInterval(100),
            markdown: markdown)
    }

    private func staleResponse(_ markdown: String) -> AgentTranscriptResponse {
        AgentTranscriptResponse(
            agentName: "Claude Code",
            projectName: "project",
            timestamp: Date().addingTimeInterval(-100),
            markdown: markdown)
    }

    @Test("A still transcript with fresh assistant text delivers the response")
    func speaksResponseAfterQuiescence() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: true,
            latestResponse: freshResponse("Done."))
        let watcher = makeWatcher(locator: locator)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .response(markdown: "Done."))
    }

    @Test("A response older than the watch never re-speaks")
    func staleResponseResolvesToolOnly() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: true,
            latestResponse: staleResponse("The previous answer."))
        let watcher = makeWatcher(locator: locator)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .toolOnly)
    }

    @Test("Extended stillness with no new assistant text is tool-only")
    func playsDoneCueAfterExtendedStillWindow() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: false,
            latestResponse: freshResponse("Interim note."))
        let watcher = makeWatcher(locator: locator)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .toolOnly)
    }

    @Test("An unreadable transcript behaves as a tool-only turn")
    func treatsUnreadableTranscriptAsToolOnlyTurn() async {
        let locator = makeLocator()
        locator.throwsError = true
        let watcher = makeWatcher(locator: locator)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .toolOnly)
    }

    @Test("An agent no locator understands resolves as tool-only")
    func unknownAgentResolvesToolOnly() async {
        let locator = makeLocator()
        let watcher = makeWatcher(locator: locator)
        let session = ResolvedAgentSession(
            agentName: "unknown-agent",
            workingDirectory: "/tmp/project",
            ttyDevice: nil)

        let events = await watcher.arm(session: session, anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .toolOnly)
    }

    @Test("A changing transcript defers completion until it goes still")
    func fileChangeDefersCompletion() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: true,
            latestResponse: freshResponse("Done."))
        let watcher = makeWatcher(locator: locator, extendedWindow: 5)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        let collector = Task { () -> (ResponseWatchEvent?, Date) in
            var iterator = events.makeAsyncIterator()
            // Appends surface as still-working notices; the test
            // waits for the resolution behind them.
            while let event = await iterator.next() {
                if event != .stillWorking { return (event, Date()) }
            }
            return (nil, Date())
        }

        // Keep the file changing well past the quiescence window.
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for _ in 0..<10 {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("more\n".utf8))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let appendsEnded = Date()

        let (event, arrivedAt) = await collector.value
        #expect(event == .response(markdown: "Done."))
        #expect(arrivedAt >= appendsEnded)
    }

    @Test("A changing transcript emits throttled still-working notices")
    func changingTranscriptEmitsStillWorking() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: false,
            latestResponse: nil)
        let watcher = makeWatcher(locator: locator, extendedWindow: 5)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        let collector = Task { () -> ResponseWatchEvent? in
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        // One append to an already-observed file is the agent at
        // work; the notice arrives without any resolution.
        try await Task.sleep(nanoseconds: 50_000_000)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tool record\n".utf8))

        #expect(await collector.value == .stillWorking)
        await watcher.cancelWatch()
    }

    @Test("Interim narration speaks a fresh mostly-prose message on arrival")
    func speaksMostlyProseInterimMessages() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: false,
            latestResponse: freshResponse("Checking the resampler."))
        let watcher = makeWatcher(
            locator: locator,
            extendedWindow: 30,
            quiescenceWindow: 30,
            narrates: true)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(
            await iterator.next()
                == .interimMessage(markdown: "Checking the resampler."))
        await watcher.cancelWatch()
    }

    @Test("A narrated response completes silently instead of re-speaking")
    func narratedResponseCompletesSilently() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: true,
            latestResponse: freshResponse("All done."))
        let watcher = makeWatcher(locator: locator, narrates: true)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .interimMessage(markdown: "All done."))
        #expect(await iterator.next() == .completed(markdown: "All done."))
    }

    @Test("A code-heavy message is not narrated and speaks at completion")
    func codeHeavyMessageSpeaksOnlyAtCompletion() async throws {
        let markdown = """
            One line.

            ```swift
            let a = 1
            let b = 2
            let c = 3
            let d = 4
            let e = a + b + c + d
            print(e, a, b, c, d)
            ```
            """
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: true,
            latestResponse: freshResponse(markdown))
        let watcher = makeWatcher(locator: locator, narrates: true)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(await iterator.next() == .response(markdown: markdown))
    }

    @Test("Narration off delivers only the completed response")
    func narrationOffSpeaksOnlyCompletion() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: true,
            latestResponse: freshResponse("Quiet until done."))
        let watcher = makeWatcher(locator: locator, narrates: false)

        let events = await watcher.arm(session: agentSession(), anchor: "Go.")
        var iterator = events.makeAsyncIterator()

        #expect(
            await iterator.next()
                == .response(markdown: "Quiet until done."))
    }

    @Test("Arming replaces the earlier watch; cancel ends the current one")
    func keepsWatchUntilCompletionReplacementOrHangup() async throws {
        let locator = makeLocator()
        let file = try makeTranscriptFile()
        defer { try? FileManager.default.removeItem(at: file) }
        locator.stubbedSessionFile = file
        locator.stubbedEdge = AgentTranscriptEdge(
            endsWithAssistantText: false,
            latestResponse: nil)
        let watcher = makeWatcher(locator: locator, extendedWindow: 30)

        let first = await watcher.arm(session: agentSession(), anchor: "One.")
        let second = await watcher.arm(session: agentSession(), anchor: "Two.")

        // The replaced watch finishes without an event.
        var firstIterator = first.makeAsyncIterator()
        #expect(await firstIterator.next() == nil)

        // The current watch survives replacement and ends on cancel.
        await watcher.cancelWatch()
        var secondIterator = second.makeAsyncIterator()
        #expect(await secondIterator.next() == nil)
    }
}
