import Foundation
import UnrambleKit

/// Mock web content reader that returns fixed content and records reads.
public final class MockWebContentReader: WebContentReading, @unchecked Sendable
{

    private let lock = NSLock()
    private var _stubbedContent: ReadableContent?
    private var _requestedProcessIdentifiers: [Int32] = []

    public init(stubbedContent: ReadableContent? = nil) {
        _stubbedContent = stubbedContent
    }

    public var stubbedContent: ReadableContent? {
        get { lock.withLock { _stubbedContent } }
        set { lock.withLock { _stubbedContent = newValue } }
    }

    public var requestedProcessIdentifiers: [Int32] {
        lock.withLock { _requestedProcessIdentifiers }
    }

    public func readMainContent(processIdentifier: Int32) async
        -> ReadableContent?
    {
        lock.withLock {
            _requestedProcessIdentifiers.append(processIdentifier)
            return _stubbedContent
        }
    }
}
