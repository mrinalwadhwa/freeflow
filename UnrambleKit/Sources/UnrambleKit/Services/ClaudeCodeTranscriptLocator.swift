import Foundation

/// Locates the latest assistant response in Claude Code session transcripts.
///
/// Claude Code stores each session as a JSONL file under
/// `~/.claude/projects/<slug>/`, where the slug is the session's working
/// directory with every character outside `[A-Za-z0-9-]` replaced by `-`.
/// Every record carries its own `cwd`, so the locator confirms the match
/// per record instead of trusting the slug rule alone.
public struct ClaudeCodeTranscriptLocator: AgentTranscriptLocating {

    public let agentName = "Claude Code"
    public let processNames: Set<String> = ["claude"]

    private let projectsDirectory: URL

    public init(
        projectsDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    ) {
        self.projectsDirectory = projectsDirectory
    }

    public func latestResponse(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptResponse? {
        let slug = Self.slug(for: processWorkingDirectory)
        let sessionDirectory = projectsDirectory.appendingPathComponent(slug)
        let sessionFiles = try TranscriptFiles.jsonlFilesByNewestFirst(
            in: sessionDirectory)

        for file in sessionFiles {
            guard !Task.isCancelled else { return nil }
            if let response = latestResponse(
                inTranscriptLines: TranscriptFiles.tailLines(of: file),
                processWorkingDirectory: processWorkingDirectory,
                fallbackTimestamp: TranscriptFiles.modificationDate(of: file))
            {
                return response
            }
        }
        return nil
    }

    public func sessionFile(
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> URL? {
        let slug = Self.slug(for: processWorkingDirectory)
        let sessionDirectory = projectsDirectory.appendingPathComponent(slug)
        return try TranscriptFiles.jsonlFilesByNewestFirst(in: sessionDirectory)
            .first
    }

    public func transcriptEdge(
        of file: URL,
        forProcessWorkingDirectory processWorkingDirectory: String
    ) throws -> AgentTranscriptEdge {
        let lines = TranscriptFiles.tailLines(of: file)
        let newestRecord = lines.reversed().lazy
            .compactMap(TranscriptFiles.jsonObject(from:))
            .first { _ in true }
        let endsWithAssistantText = newestRecord.map { record in
            guard record["type"] as? String == "assistant" else { return false }
            if let recordWorkingDirectory = record["cwd"] as? String,
                !TranscriptFiles.pathsShareLineage(
                    recordWorkingDirectory, processWorkingDirectory)
            {
                return false
            }
            return assistantText(of: record) != nil
        }
        return AgentTranscriptEdge(
            endsWithAssistantText: endsWithAssistantText ?? false,
            latestResponse: latestResponse(
                inTranscriptLines: lines,
                processWorkingDirectory: processWorkingDirectory,
                fallbackTimestamp: TranscriptFiles.modificationDate(of: file)))
    }

    private func latestResponse(
        inTranscriptLines lines: [String],
        processWorkingDirectory: String,
        fallbackTimestamp: Date
    ) -> AgentTranscriptResponse? {
        for line in lines.reversed() {
            guard let record = TranscriptFiles.jsonObject(from: line) else {
                continue
            }
            guard record["type"] as? String == "assistant" else { continue }
            if let recordWorkingDirectory = record["cwd"] as? String,
                !TranscriptFiles.pathsShareLineage(
                    recordWorkingDirectory, processWorkingDirectory)
            {
                continue
            }
            guard let text = assistantText(of: record), !text.isEmpty else {
                continue
            }
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

    private func assistantText(of record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else { return nil }
        let parts = content.compactMap { part -> String? in
            guard part["type"] as? String == "text",
                let text = part["text"] as? String,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    /// Map a working directory to its Claude Code project directory name.
    ///
    /// The rule is ASCII-only: every character outside `[A-Za-z0-9-]`
    /// becomes `-`, including non-ASCII letters, so the result matches the
    /// directory names Claude Code creates.
    static func slug(for workingDirectory: String) -> String {
        String(
            workingDirectory.map { character in
                let isASCIIAlphanumeric =
                    character.isASCII && (character.isLetter || character.isNumber)
                return isASCIIAlphanumeric || character == "-" ? character : "-"
            })
    }
}
