import Foundation

/// Lightweight logging utility that writes to stderr for immediate flushing.
///
/// `debugPrint` writes to stdout, which is block-buffered when redirected
/// to a file. This means log output can be delayed by minutes, making it
/// impossible to diagnose hangs. Stderr is line-buffered (or unbuffered)
/// by default, so writes appear immediately.
///
/// Usage:
///   Log.debug("[Pipeline] activate() called")
///   Log.debug("[Pipeline] audio stopped (\(duration)s)")
public enum Log {
    /// Write a debug message to stderr with immediate flush.
    ///
    /// Output format matches `debugPrint` style: the message is quoted
    /// and followed by a newline.
    public static func debug(_ message: String) {
        let line = "\"\(message)\"\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
