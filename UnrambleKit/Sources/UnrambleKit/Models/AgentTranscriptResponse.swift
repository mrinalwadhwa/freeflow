import Foundation

/// The most recent assistant response found in a coding-agent transcript.
public struct AgentTranscriptResponse: Sendable, Equatable {

    /// Display name of the agent, e.g. "Claude Code".
    public let agentName: String

    /// Short name of the project the session runs in, e.g. "unramble".
    public let projectName: String

    /// When the response was recorded, from the transcript's own timestamp
    /// or the transcript file's modification time.
    public let timestamp: Date

    /// The response text as the agent produced it, typically markdown.
    public let markdown: String

    public init(
        agentName: String,
        projectName: String,
        timestamp: Date,
        markdown: String
    ) {
        self.agentName = agentName
        self.projectName = projectName
        self.timestamp = timestamp
        self.markdown = markdown
    }
}
