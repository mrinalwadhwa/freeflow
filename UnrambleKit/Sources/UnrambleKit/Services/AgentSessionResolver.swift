import Foundation

/// Resolves the coding-agent session behind the frontmost application.
///
/// Uses the same selection the transcript source uses for reading:
/// agent processes in the frontmost app's descendant tree, narrowed to
/// the focused terminal pane's tty when the terminal reports it. A
/// session qualifies only when its locator finds a session transcript
/// file, so a call never starts against an agent that cannot be
/// watched. Unlike reading, resolution does not require an assistant
/// response — a fresh session the user speaks to first still counts.
public struct AgentSessionResolver: AgentSessionResolving {

    private let finder: AgentProcessFinder
    private let locators: [any AgentTranscriptLocating]
    private let terminalFocusReader: (any TerminalFocusReading)?

    public init(
        processTable: any ProcessTableProviding,
        locators: [any AgentTranscriptLocating] = [
            ClaudeCodeTranscriptLocator(),
            CodexTranscriptLocator(),
        ],
        terminalFocusReader: (any TerminalFocusReading)? = nil
    ) {
        self.finder = AgentProcessFinder(processTable: processTable)
        self.locators = locators
        self.terminalFocusReader = terminalFocusReader
    }

    public func resolveSession(
        for context: AppContext
    ) async -> ResolvedAgentSession? {
        guard let rootPid = context.processIdentifier else { return nil }

        var matchedNames: Set<String> = []
        for locator in locators {
            matchedNames.formUnion(locator.processNames)
        }
        var agents = finder.findAgents(under: rootPid, matching: matchedNames)
        if agents.isEmpty, context.isTerminal {
            // Terminal server architectures (iTerm 3.6) parent the
            // sessions to a daemon beside the GUI app; scan the whole
            // table and let the focused tty scope the pick.
            agents = finder.findAgents(matching: matchedNames)
        }
        guard !agents.isEmpty else { return nil }

        // Scope to the focused pane when the terminal names its tty,
        // so the call binds to the session that receives typed text.
        var candidates = agents
        if agents.count > 1, let terminalFocusReader,
            let focusedTTY = await terminalFocusReader.focusedSessionTTY(
                bundleID: context.bundleID)
        {
            let focused = agents.filter { $0.ttyDevice == focusedTTY }
            if !focused.isEmpty {
                candidates = focused
            }
        }

        for agent in candidates {
            for locator in locators
            where locator.processNames.contains(agent.name) {
                guard
                    (try? locator.sessionFile(
                        forProcessWorkingDirectory: agent.workingDirectory))
                        ?? nil != nil
                else { continue }
                return ResolvedAgentSession(
                    agentName: agent.name,
                    workingDirectory: agent.workingDirectory,
                    ttyDevice: agent.ttyDevice)
            }
        }
        return nil
    }
}
