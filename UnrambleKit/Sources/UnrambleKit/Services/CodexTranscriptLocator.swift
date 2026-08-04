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

    public func sessionFile(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> URL? {
        let candidates = TranscriptFiles.jsonlFilesByNewestFirst(
            underTree: sessionsDirectory,
            limit: candidateLimit)
        return candidates.first {
            sessionMatches(
                file: $0,
                processWorkingDirectory: processWorkingDirectory)
        }
    }

    public func sessionFile(
        forProcessWorkingDirectory processWorkingDirectory: String,
        containing anchor: String
    ) throws -> URL? {
        let candidates = TranscriptFiles.jsonlFilesByNewestFirst(
            underTree: sessionsDirectory,
            limit: candidateLimit)
        // The anchor appears JSON-escaped inside the rollout's
        // user_message record; search for an escaped fragment long
        // enough to be unambiguous.
        let fragment = Self.escapedAnchorFragment(of: anchor)
        guard !fragment.isEmpty else {
            return try sessionFile(
                forProcessWorkingDirectory: processWorkingDirectory)
        }
        for file in candidates {
            guard !Task.isCancelled else { return nil }
            guard
                sessionMatches(
                    file: file,
                    processWorkingDirectory: processWorkingDirectory)
            else { continue }
            let tail = TranscriptFiles.tailLines(of: file)
            if tail.contains(where: { $0.contains(fragment) }) {
                return file
            }
        }
        return nil
    }

    /// The anchor as it appears inside a JSONL record: JSON-escaped,
    /// truncated to a distinctive prefix.
    static func escapedAnchorFragment(of anchor: String) -> String {
        let escaped = anchor
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return String(escaped.prefix(60))
    }

    public func transcriptEdge(
        of file: URL,
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptEdge {
        let lines = TranscriptFiles.tailLines(of: file)
        return AgentTranscriptEdge(
            endsWithAssistantText: Self.turnEndsWithAssistantText(
                inRolloutLines: lines),
            latestResponse: latestResponse(
                inRolloutLines: lines,
                processWorkingDirectory: processWorkingDirectory,
                fallbackTimestamp: TranscriptFiles.modificationDate(of: file)))
    }

    /// Whether the rollout's edge is a finished assistant turn.
    ///
    /// Only Codex's explicit `task_complete` record ends a turn.
    /// Codex prints mid-turn progress messages — an assistant message
    /// plus `token_count`, then more reasoning — so a message at the
    /// edge proves nothing; a watch that trusted it resolved while
    /// Codex was mid-flow and its real final went unheard. The
    /// `task_complete` lands milliseconds after the true final
    /// message, so believing only it costs nothing and cannot lie.
    /// Bookkeeping after it is walked over; anything else at the edge
    /// means the turn is still open.
    static func turnEndsWithAssistantText(
        inRolloutLines lines: [String]
    ) -> Bool {
        for line in lines.reversed() {
            guard let record = TranscriptFiles.jsonObject(from: line) else {
                continue
            }
            let recordType = record["type"] as? String
            let payload = record["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String
            switch recordType {
            case "event_msg":
                switch payloadType {
                case "task_complete":
                    return true
                case "token_count":
                    continue
                default:
                    return false
                }
            case "world_state", "turn_context", "session_meta":
                continue
            default:
                return false
            }
        }
        return false
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
                let text = Self.assistantText(of: payload),
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

    private static func assistantText(of payload: [String: Any]) -> String? {
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
