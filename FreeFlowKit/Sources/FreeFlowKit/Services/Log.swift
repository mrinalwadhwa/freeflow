import Foundation

/// Lightweight logging utility that writes to stderr for immediate flushing
/// and maintains an in-memory ring buffer of recent entries for diagnostics.
///
/// `debugPrint` writes to stdout, which is block-buffered when redirected
/// to a file. This means log output can be delayed by minutes, making it
/// impossible to diagnose hangs. Stderr is line-buffered (or unbuffered)
/// by default, so writes appear immediately.
///
/// The ring buffer stores the last 500 log entries with timestamps. It is
/// always active, including in release builds. When a user reports an issue
/// via "Report an Issue..." in the menu bar, `formattedHistory()` dumps the
/// buffer into the GitHub issue body.
///
/// Usage:
///   Log.debug("[Pipeline] activate() called")
///   Log.debug("[Pipeline] audio stopped (\(duration)s)")
///   let history = Log.formattedHistory()
public enum Log {

    /// Maximum number of entries retained in the ring buffer.
    private static let maxEntries = 500

    /// Lock protecting the ring buffer. Using `os_unfair_lock` for minimal
    /// overhead on the hot path (every log call).
    private static let lock = NSLock()

    /// Circular buffer of recent log entries.
    private static var entries: [Entry] = []

    /// A single log entry with a timestamp and message.
    private struct Entry {
        let timestamp: Date
        let message: String
    }

    /// Write a debug message to stderr with immediate flush and record it
    /// in the ring buffer.
    ///
    /// Output format matches `debugPrint` style: the message is quoted
    /// and followed by a newline.
    public static func debug(_ message: String) {
        let now = Date()

        // Write to stderr for immediate visibility in debug builds and
        // when the app is launched from a terminal.
        let line = "\"\(message)\"\n"
        FileHandle.standardError.write(Data(line.utf8))

        // Record in ring buffer (always, including release builds).
        lock.lock()
        entries.append(Entry(timestamp: now, message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()
    }

    /// Format the ring buffer as a diagnostic string suitable for pasting
    /// into a GitHub issue.
    ///
    /// Each line is prefixed with a relative timestamp (seconds since the
    /// oldest entry) for compact, readable output. Returns a message
    /// indicating an empty log if no entries have been recorded.
    public static func formattedHistory() -> String {
        lock.lock()
        let snapshot = entries
        lock.unlock()

        guard let first = snapshot.first else {
            return "No log entries recorded."
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        let origin = first.timestamp
        var lines: [String] = []
        lines.append(
            "Log (\(snapshot.count) entries, \(formatter.string(from: origin)) – \(formatter.string(from: snapshot.last!.timestamp)))"
        )
        lines.append("")

        for entry in snapshot {
            let elapsed = entry.timestamp.timeIntervalSince(origin)
            let prefix = String(format: "+%07.3f", elapsed)
            lines.append("\(prefix) \(entry.message)")
        }

        return lines.joined(separator: "\n")
    }

    /// The number of entries currently in the ring buffer.
    public static var entryCount: Int {
        lock.lock()
        let count = entries.count
        lock.unlock()
        return count
    }

    /// Clear all entries from the ring buffer.
    public static func clearHistory() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
