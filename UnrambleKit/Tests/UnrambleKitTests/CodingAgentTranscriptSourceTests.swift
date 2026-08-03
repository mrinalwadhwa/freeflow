import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Coding-agent transcript source")
struct CodingAgentTranscriptSourceTests {

    private func terminalContext(
        pid: Int32?, windowTitle: String = "project"
    ) -> AppContext {
        AppContext(
            bundleID: "com.googlecode.iterm2",
            appName: "iTerm2",
            windowTitle: windowTitle,
            processIdentifier: pid)
    }

    private func table(
        agents: [(pid: Int32, name: String, cwd: String)],
        ttyDevices: [Int32: Int32] = [:]
    ) -> FakeProcessTable {
        var records: [ProcessTableRecord] = [
            .init(pid: 100, parentPid: 1, name: "iTerm2")
        ]
        var workingDirectories: [Int32: String] = [:]
        for agent in agents {
            records.append(
                .init(
                    pid: agent.pid, parentPid: 100, name: agent.name,
                    ttyDevice: ttyDevices[agent.pid]))
            workingDirectories[agent.pid] = agent.cwd
        }
        return FakeProcessTable(
            records: records, workingDirectories: workingDirectories)
    }

    private func response(
        agent: String,
        project: String,
        text: String,
        at seconds: TimeInterval
    ) -> AgentTranscriptResponse {
        AgentTranscriptResponse(
            agentName: agent,
            projectName: project,
            timestamp: Date(timeIntervalSince1970: seconds),
            markdown: text)
    }

    @Test("Speaks the single reachable session without attribution")
    func singleSessionHasNoAttribution() async throws {
        let locator = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "project",
                text: "The answer.",
                at: 100))
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [(200, "claude", "/p")]),
            locators: [locator])

        let content = try await source.readContent(
            for: terminalContext(pid: 100))

        #expect(content?.attribution == nil)
        #expect(content?.segments == [.init(kind: .prose, text: "The answer.")])
        #expect(locator.requestedWorkingDirectories == ["/p"])
    }

    @Test("Picks the newest response across sessions and attributes it")
    func newestSessionWinsWithAttribution() async throws {
        let claude = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "alpha",
                text: "Older.",
                at: 100))
        let codex = StubAgentTranscriptLocator(
            agentName: "Codex",
            processNames: ["codex"],
            stubbedResponse: response(
                agent: "Codex",
                project: "beta",
                text: "Newer.",
                at: 200))
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [
                (200, "claude", "/alpha"), (300, "codex", "/beta"),
            ]),
            locators: [claude, codex])

        let content = try await source.readContent(
            for: terminalContext(pid: 100))

        #expect(content?.attribution == "Codex in beta")
        #expect(content?.segments == [.init(kind: .prose, text: "Newer.")])
    }

    @Test("The focused pane's session beats a newer sibling session")
    func focusedPaneBeatsNewerSession() async throws {
        let claude = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "alpha",
                text: "Focused but older.",
                at: 100))
        let codex = StubAgentTranscriptLocator(
            agentName: "Codex",
            processNames: ["codex"],
            stubbedResponse: response(
                agent: "Codex",
                project: "beta",
                text: "Newer but elsewhere.",
                at: 200))
        let focusReader = MockTerminalFocusReader(stubbedTTYDevice: 7)
        let source = CodingAgentTranscriptSource(
            processTable: table(
                agents: [(200, "claude", "/alpha"), (300, "codex", "/beta")],
                ttyDevices: [200: 7, 300: 9]),
            locators: [claude, codex],
            terminalFocusReader: focusReader)

        let content = try await source.readContent(
            for: terminalContext(pid: 100))

        // A focused-pane match speaks unannounced: attribution exists to
        // confirm a guess, and this is not a guess.
        #expect(content?.attribution == nil)
        #expect(
            content?.segments == [
                .init(kind: .prose, text: "Focused but older.")
            ])
        #expect(focusReader.requestedBundleIDs == ["com.googlecode.iterm2"])
    }

    @Test("An unmatched focused tty falls back to all sessions")
    func unmatchedFocusedTTYFallsBack() async throws {
        let claude = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "alpha",
                text: "Older.",
                at: 100))
        let codex = StubAgentTranscriptLocator(
            agentName: "Codex",
            processNames: ["codex"],
            stubbedResponse: response(
                agent: "Codex",
                project: "beta",
                text: "Newest.",
                at: 200))
        let source = CodingAgentTranscriptSource(
            processTable: table(
                agents: [(200, "claude", "/alpha"), (300, "codex", "/beta")],
                ttyDevices: [200: 7, 300: 9]),
            locators: [claude, codex],
            terminalFocusReader: MockTerminalFocusReader(stubbedTTYDevice: 42))

        let content = try await source.readContent(
            for: terminalContext(pid: 100))

        #expect(content?.segments == [.init(kind: .prose, text: "Newest.")])
    }

    @Test("A window title naming the agent beats a newer session")
    func titleNamingAgentBeatsNewerSession() async throws {
        let claude = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "alpha",
                text: "Named in title.",
                at: 100))
        let codex = StubAgentTranscriptLocator(
            agentName: "Codex",
            processNames: ["codex"],
            stubbedResponse: response(
                agent: "Codex",
                project: "beta",
                text: "Newer.",
                at: 200))
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [
                (200, "claude", "/alpha"), (300, "codex", "/beta"),
            ]),
            locators: [claude, codex])

        let content = try await source.readContent(
            for: terminalContext(pid: 100, windowTitle: "alpha — claude"))

        #expect(
            content?.segments == [.init(kind: .prose, text: "Named in title.")])
    }

    @Test("A window title naming the project breaks a same-agent tie")
    func titleNamingProjectBreaksTie() async throws {
        let alpha = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "alpha",
                text: "In the titled project.",
                at: 100))
        let beta = StubAgentTranscriptLocator(
            agentName: "Codex",
            processNames: ["codex"],
            stubbedResponse: response(
                agent: "Codex",
                project: "beta",
                text: "Newer elsewhere.",
                at: 200))
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [
                (200, "claude", "/alpha"), (300, "codex", "/beta"),
            ]),
            locators: [alpha, beta])

        let content = try await source.readContent(
            for: terminalContext(pid: 100, windowTitle: "~/Workspace/alpha"))

        #expect(
            content?.segments == [
                .init(kind: .prose, text: "In the titled project.")
            ])
    }

    @Test("Two panes of the same session keep attribution nil")
    func samSessionPanesKeepAttributionNil() async throws {
        let locator = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"],
            stubbedResponse: response(
                agent: "Claude Code",
                project: "project",
                text: "Same session.",
                at: 100))
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [
                (200, "claude", "/p"), (201, "claude", "/p"),
            ]),
            locators: [locator])

        let content = try await source.readContent(
            for: terminalContext(pid: 100))

        #expect(content?.attribution == nil)
        #expect(
            content?.segments == [.init(kind: .prose, text: "Same session.")])
    }

    @Test("A failing locator falls through to a readable session")
    func failingLocatorFallsThrough() async throws {
        let failing = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"])
        failing.throwsError = true
        let working = StubAgentTranscriptLocator(
            agentName: "Codex",
            processNames: ["codex"],
            stubbedResponse: response(
                agent: "Codex",
                project: "beta",
                text: "Still readable.",
                at: 50))
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [
                (200, "claude", "/alpha"), (300, "codex", "/beta"),
            ]),
            locators: [failing, working])

        let content = try await source.readContent(
            for: terminalContext(pid: 100))

        #expect(
            content?.segments == [.init(kind: .prose, text: "Still readable.")])
    }

    @Test("Returns nil when the snapshot has no process identifier")
    func returnsNilWithoutPid() async throws {
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [(200, "claude", "/p")]),
            locators: [
                StubAgentTranscriptLocator(
                    agentName: "Claude Code", processNames: ["claude"])
            ])
        #expect(
            try await source.readContent(for: terminalContext(pid: nil)) == nil)
    }

    @Test("Returns nil when no agent runs under the frontmost app")
    func returnsNilWithoutAgents() async throws {
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: []),
            locators: [
                StubAgentTranscriptLocator(
                    agentName: "Claude Code", processNames: ["claude"])
            ])
        #expect(
            try await source.readContent(for: terminalContext(pid: 100)) == nil)
    }

    @Test("Returns nil when no transcript matches a found agent")
    func returnsNilWithoutTranscripts() async throws {
        let source = CodingAgentTranscriptSource(
            processTable: table(agents: [(200, "claude", "/p")]),
            locators: [
                StubAgentTranscriptLocator(
                    agentName: "Claude Code", processNames: ["claude"])
            ])
        #expect(
            try await source.readContent(for: terminalContext(pid: 100)) == nil)
    }
}
