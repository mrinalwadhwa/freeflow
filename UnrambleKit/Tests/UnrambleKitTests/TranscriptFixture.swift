import Foundation

/// Build transcript fixture trees in a temporary directory.
struct TranscriptFixture {

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("unramble-transcripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Write records as JSONL under a relative path, with an optional
    /// explicit modification date so newest-first ordering is deterministic.
    @discardableResult
    func writeJSONL(
        at relativePath: String,
        records: [[String: Any]],
        modifiedAt: Date? = nil
    ) throws -> URL {
        let file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let lines = try records.map { record -> String in
            let data = try JSONSerialization.data(withJSONObject: record)
            return String(decoding: data, as: UTF8.self)
        }
        try lines.joined(separator: "\n").write(
            to: file, atomically: true, encoding: .utf8)
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt], ofItemAtPath: file.path)
        }
        return file
    }

    // MARK: - Claude Code records

    static func claudeAssistant(
        text: String,
        cwd: String? = nil,
        timestamp: String? = "2026-08-01T10:00:00.000Z"
    ) -> [String: Any] {
        claudeAssistant(parts: [text], cwd: cwd, timestamp: timestamp)
    }

    static func claudeAssistant(
        parts: [String],
        cwd: String? = nil,
        timestamp: String? = "2026-08-01T10:00:00.000Z"
    ) -> [String: Any] {
        var record: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": parts.map { ["type": "text", "text": $0] },
            ],
        ]
        if let timestamp { record["timestamp"] = timestamp }
        if let cwd { record["cwd"] = cwd }
        return record
    }

    static func claudeToolUseAssistant(cwd: String? = nil) -> [String: Any] {
        var record: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-08-01T10:00:00.000Z",
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "name": "Bash"]],
            ],
        ]
        if let cwd { record["cwd"] = cwd }
        return record
    }

    static func claudeUser(text: String) -> [String: Any] {
        [
            "type": "user",
            "timestamp": "2026-08-01T10:01:00.000Z",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ]
    }

    // MARK: - Codex records

    static func codexSessionMeta(
        cwd: String,
        threadSource: String? = nil,
        subagentSource: Bool = false
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "cwd": cwd,
            "originator": "codex-tui",
        ]
        if let threadSource { payload["thread_source"] = threadSource }
        if subagentSource {
            payload["source"] = ["subagent": ["other": "reviewer"]]
        }
        return [
            "type": "session_meta",
            "timestamp": "2026-08-01T09:00:00.000Z",
            "payload": payload,
        ]
    }

    static func codexAssistant(
        text: String,
        timestamp: String? = "2026-08-01T10:00:00.000Z"
    ) -> [String: Any] {
        codexAssistant(parts: [text], timestamp: timestamp)
    }

    static func codexAssistant(
        parts: [String],
        timestamp: String? = "2026-08-01T10:00:00.000Z"
    ) -> [String: Any] {
        var record: [String: Any] = [
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": parts.map { ["type": "output_text", "text": $0] },
            ],
        ]
        if let timestamp { record["timestamp"] = timestamp }
        return record
    }

    static func codexEvent() -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": "2026-08-01T10:02:00.000Z",
            "payload": ["type": "task_started"],
        ]
    }
}
