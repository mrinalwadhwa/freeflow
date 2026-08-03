import Foundation
import UnrambleKit

/// Mock selection reader that returns a stubbed selection.
public final class MockSelectionReader: SelectionReading, @unchecked Sendable {

    private let lock = NSLock()
    private var _stubbedSelection: String?
    private var _readCount = 0

    public init(stubbedSelection: String? = nil) {
        _stubbedSelection = stubbedSelection
    }

    public var stubbedSelection: String? {
        get { lock.withLock { _stubbedSelection } }
        set { lock.withLock { _stubbedSelection = newValue } }
    }

    public var readCount: Int {
        lock.withLock { _readCount }
    }

    public func readSelectedText() async -> String? {
        lock.withLock {
            _readCount += 1
            return _stubbedSelection
        }
    }
}
