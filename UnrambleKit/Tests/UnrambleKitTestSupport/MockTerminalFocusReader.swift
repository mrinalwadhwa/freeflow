import Foundation
import UnrambleKit

/// Mock terminal focus reader that returns a fixed tty device number.
public final class MockTerminalFocusReader: TerminalFocusReading,
    @unchecked Sendable
{

    private let lock = NSLock()
    private var _stubbedTTYDevice: Int32?
    private var _requestedBundleIDs: [String] = []

    public init(stubbedTTYDevice: Int32? = nil) {
        _stubbedTTYDevice = stubbedTTYDevice
    }

    public var stubbedTTYDevice: Int32? {
        get { lock.withLock { _stubbedTTYDevice } }
        set { lock.withLock { _stubbedTTYDevice = newValue } }
    }

    public var requestedBundleIDs: [String] {
        lock.withLock { _requestedBundleIDs }
    }

    public func focusedSessionTTY(bundleID: String) async -> Int32? {
        lock.withLock {
            _requestedBundleIDs.append(bundleID)
            return _stubbedTTYDevice
        }
    }
}
