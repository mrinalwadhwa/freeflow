import Foundation
import UnrambleKit

/// Fake process table backed by in-memory records.
public final class FakeProcessTable: ProcessTableProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var _records: [ProcessTableRecord]
    private var _workingDirectories: [Int32: String]

    public init(
        records: [ProcessTableRecord] = [],
        workingDirectories: [Int32: String] = [:]
    ) {
        _records = records
        _workingDirectories = workingDirectories
    }

    public var records: [ProcessTableRecord] {
        get { lock.withLock { _records } }
        set { lock.withLock { _records = newValue } }
    }

    public var workingDirectories: [Int32: String] {
        get { lock.withLock { _workingDirectories } }
        set { lock.withLock { _workingDirectories = newValue } }
    }

    public func snapshot() -> [ProcessTableRecord] {
        lock.withLock { _records }
    }

    public func currentWorkingDirectory(of pid: Int32) -> String? {
        lock.withLock { _workingDirectories[pid] }
    }
}
