import Foundation

/// One process in a point-in-time snapshot of the process table.
public struct ProcessTableRecord: Sendable, Equatable {
    public let pid: Int32
    public let parentPid: Int32

    /// The process's short executable name (BSD `comm`, truncated by the
    /// kernel to 16 characters).
    public let name: String

    /// The device number of the process's controlling terminal, or nil
    /// when it has none. Correlates a process with the terminal pane that
    /// hosts it.
    public let ttyDevice: Int32?

    public init(
        pid: Int32,
        parentPid: Int32,
        name: String,
        ttyDevice: Int32? = nil
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.name = name
        self.ttyDevice = ttyDevice
    }
}
