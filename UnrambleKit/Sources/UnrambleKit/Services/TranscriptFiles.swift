import Foundation

/// Shared file and JSON helpers for transcript locators.
enum TranscriptFiles {

    /// Return the `.jsonl` files directly inside a directory, newest
    /// modification first. A missing directory yields an empty list.
    static func jsonlFilesByNewestFirst(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        return
            files
            .filter { $0.pathExtension == "jsonl" }
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
    }

    /// Return all `.jsonl` files under a directory tree, newest first,
    /// capped to bound work on large histories.
    static func jsonlFilesByNewestFirst(
        underTree root: URL,
        limit: Int
    ) -> [URL] {
        let fileManager = FileManager.default
        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" {
            files.append(url)
        }
        return
            files
            .sorted { modificationDate(of: $0) > modificationDate(of: $1) }
            .prefix(limit)
            .map { $0 }
    }

    static func modificationDate(of file: URL) -> Date {
        let values = try? file.resourceValues(
            forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    /// Read only the first line of a file, up to a byte cap.
    static func firstLine(of file: URL, maximumBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes) else {
            return nil
        }
        let lineData = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        return String(data: lineData, encoding: .utf8)
    }

    /// Read the last complete lines of a file, up to a byte cap.
    ///
    /// Transcript files grow to many megabytes; scanning for the latest
    /// assistant response only needs the tail. When the file exceeds the
    /// cap, the first (possibly partial) line of the window is dropped.
    static func tailLines(
        of file: URL,
        maximumBytes: Int = 4 * 1024 * 1024
    ) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return []
        }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }

        let start = end > UInt64(maximumBytes) ? end - UInt64(maximumBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
            let data = try? handle.readToEnd(),
            let text = String(data: data, encoding: .utf8)
                ?? String(
                    data: data.drop(while: { $0 & 0b1100_0000 == 0b1000_0000 }),
                    encoding: .utf8)
        else { return [] }

        var lines = text.components(separatedBy: "\n")
        if start > 0, lines.count > 1 {
            lines.removeFirst()
        }
        return lines
    }

    static func jsonObject(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Whether one path equals the other or is an ancestor or descendant of
    /// it. Transcript records may carry a subdirectory of the process
    /// working directory, or the reverse, so lineage in either direction
    /// counts as a match.
    static func pathsShareLineage(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        return first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }

    static func date(fromISO8601 string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }

    static func projectName(of workingDirectory: String) -> String {
        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty ? workingDirectory : name
    }
}
