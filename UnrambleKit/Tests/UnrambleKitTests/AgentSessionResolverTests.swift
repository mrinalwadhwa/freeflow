import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Agent session resolver")
struct AgentSessionResolverTests {

    private func terminalContext(pid: Int32?) -> AppContext {
        AppContext(
            bundleID: "com.googlecode.iterm2",
            appName: "iTerm2",
            windowTitle: "project",
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

    private func locator(
        sessionFile: URL? = URL(fileURLWithPath: "/tmp/session.jsonl")
    ) -> StubAgentTranscriptLocator {
        let locator = StubAgentTranscriptLocator(
            agentName: "Claude Code",
            processNames: ["claude"])
        locator.stubbedSessionFile = sessionFile
        return locator
    }

    @Test("Resolves the single reachable agent session")
    func resolvesSingleSession() async {
        let resolver = AgentSessionResolver(
            processTable: table(agents: [(200, "claude", "/p")]),
            locators: [locator()])

        let session = await resolver.resolveSession(
            for: terminalContext(pid: 100))

        #expect(session?.agentName == "claude")
        #expect(session?.workingDirectory == "/p")
    }

    @Test("The focused pane's tty narrows several sessions")
    func focusedPaneNarrowsSessions() async {
        let focusReader = MockTerminalFocusReader(stubbedTTYDevice: 7)
        let resolver = AgentSessionResolver(
            processTable: table(
                agents: [
                    (200, "claude", "/alpha"),
                    (201, "claude", "/beta"),
                ],
                ttyDevices: [200: 6, 201: 7]),
            locators: [locator()],
            terminalFocusReader: focusReader)

        let session = await resolver.resolveSession(
            for: terminalContext(pid: 100))

        #expect(session?.workingDirectory == "/beta")
        #expect(session?.ttyDevice == 7)
    }

    @Test("An agent without a session transcript file does not resolve")
    func requiresSessionFile() async {
        let resolver = AgentSessionResolver(
            processTable: table(agents: [(200, "claude", "/p")]),
            locators: [locator(sessionFile: nil)])

        let session = await resolver.resolveSession(
            for: terminalContext(pid: 100))

        #expect(session == nil)
    }

    @Test("An agent behind a sibling terminal server daemon resolves")
    func resolvesAgentBehindSiblingServerDaemon() async {
        // iTerm 3.6 parents sessions to a server daemon beside the GUI
        // app: the agent does not descend from the frontmost pid.
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 1, name: "iTerm2"),
                .init(pid: 4938, parentPid: 1, name: "iTermServer-3.6.10"),
                .init(pid: 4939, parentPid: 4938, name: "login"),
                .init(pid: 4940, parentPid: 4939, name: "zsh"),
                .init(pid: 200, parentPid: 4940, name: "claude"),
            ],
            workingDirectories: [200: "/p"])
        let resolver = AgentSessionResolver(
            processTable: table,
            locators: [locator()])

        let session = await resolver.resolveSession(
            for: terminalContext(pid: 100))

        #expect(session?.agentName == "claude")
        #expect(session?.workingDirectory == "/p")
    }

    @Test("A non-terminal app never falls back to the table-wide scan")
    func nonTerminalAppDoesNotScanTableWide() async {
        let table = FakeProcessTable(
            records: [
                .init(pid: 100, parentPid: 1, name: "Safari"),
                .init(pid: 200, parentPid: 1, name: "claude"),
            ],
            workingDirectories: [200: "/p"])
        let resolver = AgentSessionResolver(
            processTable: table,
            locators: [locator()])

        let context = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "project",
            processIdentifier: 100)
        let session = await resolver.resolveSession(for: context)

        #expect(session == nil)
    }

    @Test("A context without a process identifier does not resolve")
    func requiresProcessIdentifier() async {
        let resolver = AgentSessionResolver(
            processTable: table(agents: [(200, "claude", "/p")]),
            locators: [locator()])

        let session = await resolver.resolveSession(
            for: terminalContext(pid: nil))

        #expect(session == nil)
    }
}
