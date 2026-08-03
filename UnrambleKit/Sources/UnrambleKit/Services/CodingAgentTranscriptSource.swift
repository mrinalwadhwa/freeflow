import Foundation

/// Reads the focused coding-agent's latest response behind the frontmost
/// app.
///
/// Finds agent processes in the frontmost app's descendant tree and asks
/// each agent's transcript locator for its latest response. Among
/// reachable sessions, the one the user is looking at wins: first the
/// session on the focused terminal pane's tty (when the terminal reports
/// it), then sessions the focused window's title names, then the most
/// recent response. When the pick was inferred (no focused-pane match)
/// among several reachable sessions, the content carries an attribution
/// naming the chosen agent and project so speech confirms the guess; a
/// focused-pane match speaks unannounced — the user is looking at it.
public struct CodingAgentTranscriptSource: ContentSourceProviding {

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

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        guard let rootPid = context.processIdentifier else { return nil }

        var matchedNames: Set<String> = []
        for locator in locators {
            matchedNames.formUnion(locator.processNames)
        }
        let agents = finder.findAgents(under: rootPid, matching: matchedNames)
        guard !agents.isEmpty else { return nil }

        // Scope to the focused pane when the terminal names its tty, so
        // the read matches the session that would receive typed text.
        var candidates = agents
        var narrowedToFocusedPane = false
        if agents.count > 1, let terminalFocusReader,
            let focusedTTY = await terminalFocusReader.focusedSessionTTY(
                bundleID: context.bundleID)
        {
            let focused = agents.filter { $0.ttyDevice == focusedTTY }
            if !focused.isEmpty {
                candidates = focused
                narrowedToFocusedPane = true
            }
        }

        var pairs: [(agent: AgentProcess, response: AgentTranscriptResponse)] =
            []
        for agent in candidates {
            for locator in locators
            where locator.processNames.contains(agent.name) {
                // A locator that fails falls through so a readable sibling
                // session can still win.
                guard
                    let response = try? locator.latestResponse(
                        forProcessWorkingDirectory: agent.workingDirectory)
                else { continue }
                pairs.append((agent, response))
            }
        }

        guard
            let chosen = pairs.max(by: { lhs, rhs in
                let lhsScore = Self.titleScore(
                    of: lhs, windowTitle: context.windowTitle)
                let rhsScore = Self.titleScore(
                    of: rhs, windowTitle: context.windowTitle)
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return lhs.response.timestamp < rhs.response.timestamp
            })?.response
        else { return nil }

        let distinctSessions = Set(
            pairs.map { "\($0.response.agentName)|\($0.response.projectName)" })
        let attribution =
            !narrowedToFocusedPane && distinctSessions.count > 1
            ? "\(chosen.agentName) in \(chosen.projectName)"
            : nil

        return ReadableContent(
            attribution: attribution,
            segments: MarkdownSegmenter.segments(from: chosen.markdown))
    }

    /// Rank a session by how strongly the focused window's title names it:
    /// the agent's process name (terminals often title tabs after the
    /// running job) outweighs the project name. Zero when the title says
    /// nothing about it.
    private static func titleScore(
        of pair: (agent: AgentProcess, response: AgentTranscriptResponse),
        windowTitle: String
    ) -> Int {
        guard !windowTitle.isEmpty else { return 0 }
        var score = 0
        if windowTitle.localizedCaseInsensitiveContains(pair.agent.name) {
            score += 2
        }
        if !pair.response.projectName.isEmpty,
            windowTitle.localizedCaseInsensitiveContains(
                pair.response.projectName)
        {
            score += 1
        }
        return score
    }
}
