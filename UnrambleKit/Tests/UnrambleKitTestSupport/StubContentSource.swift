import Foundation
import UnrambleKit

/// Stub content source that returns fixed content, throws, or blocks.
public final class StubContentSource: ContentSourceProviding, @unchecked Sendable {

    public struct StubError: Error {
        public init() {}
    }

    private let lock = NSLock()
    private var _stubbedContent: ReadableContent?
    private var _throwsError = false
    private var _blocksUntilCancelled = false
    private var _readCount = 0

    public init(stubbedContent: ReadableContent? = nil) {
        _stubbedContent = stubbedContent
    }

    public var stubbedContent: ReadableContent? {
        get { lock.withLock { _stubbedContent } }
        set { lock.withLock { _stubbedContent = newValue } }
    }

    public var throwsError: Bool {
        get { lock.withLock { _throwsError } }
        set { lock.withLock { _throwsError = newValue } }
    }

    /// When true, `readContent` sleeps until its task is cancelled, so
    /// tests can exercise stopping a session during acquisition.
    public var blocksUntilCancelled: Bool {
        get { lock.withLock { _blocksUntilCancelled } }
        set { lock.withLock { _blocksUntilCancelled = newValue } }
    }

    public var readCount: Int {
        lock.withLock { _readCount }
    }

    public func readContent(for context: AppContext) async throws
        -> ReadableContent?
    {
        lock.withLock { _readCount += 1 }
        if blocksUntilCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return nil
        }
        if throwsError { throw StubError() }
        return stubbedContent
    }
}
