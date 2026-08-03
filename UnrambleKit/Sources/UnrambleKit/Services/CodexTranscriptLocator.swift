import Foundation

/// Locates the latest assistant response in Codex rollout transcripts.
///
/// Codex stores each session as a JSONL rollout under
/// `~/.codex/sessions/YYYY/MM/DD/`. The first record, `session_meta`,
/// carries the session's working directory and provenance. Subagent
/// rollouts record internal machine-readable output as assistant messages,
/// so only interactive sessions are readable.
public struct CodexTranscriptLocator: AgentTranscriptLocating {

    public let agentName = "Codex"
    public let processNames: Set<String> = ["codex"]

    private let sessionsDirectory: URL

    /// How many of the newest rollout files to consider per lookup.
    private let candidateLimit: Int

    public init(
        sessionsDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions"),
        candidateLimit: Int = 40
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.candidateLimit = candidateLimit
    }

    public func latestResponse(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptResponse? {
        let candidates = TranscriptFiles.jsonlFilesByNewestFirst(
            underTree: sessionsDirectory,
            limit: candidateLimit)

        for file in candidates {
            guard !Task.isCancelled else { return nil }
            guard
                sessionMatches(
                    file: file,
                    processWorkingDirectory: processWorkingDirectory)
            else { continue }
            if let response = latestResponse(
                inRolloutLines: TranscriptFiles.tailLines(of: file),
                processWorkingDirectory: processWorkingDirectory,
                fallbackTimestamp: TranscriptFiles.modificationDate(of: file))
            {
                return response
            }
        }
        return nil
    }

    /// Check the rollout's `session_meta` without reading the whole file.
    private func sessionMatches(
        file: URL,
        processWorkingDirectory: String
    ) -> Bool {
        guard let firstLine = TranscriptFiles.firstLine(of: file),
            let record = TranscriptFiles.jsonObject(from: firstLine),
            record["type"] as? String == "session_meta",
            let payload = record["payload"] as? [String: Any]
        else { return false }

        if payload["thread_source"] as? String == "subagent" { return false }
        if let source = payload["source"] as? [String: Any],
            source["subagent"] != nil
        {
            return false
        }
        guard let sessionWorkingDirectory = payload["cwd"] as? String else {
            return false
        }
        return TranscriptFiles.pathsShareLineage(
            sessionWorkingDirectory, processWorkingDirectory)
    }

    private func latestResponse(
        inRolloutLines lines: [String],
        processWorkingDirectory: String,
        fallbackTimestamp: Date
    ) -> AgentTranscriptResponse? {
        for line in lines.reversed() {
            guard let record = TranscriptFiles.jsonObject(from: line),
                record["type"] as? String == "response_item",
                let payload = record["payload"] as? [String: Any],
                payload["type"] as? String == "message",
                payload["role"] as? String == "assistant",
                let text = assistantText(of: payload),
                !text.isEmpty
            else { continue }

            let timestamp = (record["timestamp"] as? String)
                .flatMap(TranscriptFiles.date(fromISO8601:))
            return AgentTranscriptResponse(
                agentName: agentName,
                projectName: TranscriptFiles.projectName(
                    of: processWorkingDirectory),
                timestamp: timestamp ?? fallbackTimestamp,
                markdown: text)
        }
        return nil
    }

    private func assistantText(of payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else {
            return nil
        }
        let parts = content.compactMap { part -> String? in
            guard let text = part["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }
}
