import Foundation

/// Locates and parses one agent's transcript files.
///
/// Each locator translates one external transcript format into
/// `AgentTranscriptResponse` at this boundary, so a schema change in an
/// agent's files stays inside its locator.
public protocol AgentTranscriptLocating: Sendable {

    /// Display name of the agent this locator understands.
    var agentName: String { get }

    /// Executable names that identify this agent in the process table.
    var processNames: Set<String> { get }

    /// Return the latest assistant response for a session whose working
    /// directory matches the given process working directory, or nil when
    /// no matching readable transcript exists.
    func latestResponse(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptResponse?

    /// Return the newest session transcript file for the working
    /// directory, or nil when none exists. The response watch stats
    /// this file cheaply between parses.
    func sessionFile(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> URL?

    /// Parse the live edge of one session transcript file.
    func transcriptEdge(
        of file: URL,
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptEdge
}
