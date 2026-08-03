import Foundation

/// Reads the process table and per-process working directories.
///
/// The real implementation uses libproc. Tests inject a fake table.
public protocol ProcessTableProviding: Sendable {

    /// Return a snapshot of all visible processes.
    func snapshot() -> [ProcessTableRecord]

    /// Return the current working directory of the given process, or nil
    /// when the process is gone or unreadable.
    func currentWorkingDirectory(of pid: Int32) -> String?
}
