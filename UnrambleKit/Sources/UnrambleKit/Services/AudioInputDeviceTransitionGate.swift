import Foundation

/// Coalesces Core Audio's device-notification bursts into one awaitable
/// stability boundary. Recording starts wait here before reserving engine
/// ownership, so a hotkey press cannot race a microphone rebuild.
final class AudioInputDeviceTransitionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var settleAt: Date?

    func begin(settleAfter delay: TimeInterval) {
        lock.withLock {
            generation &+= 1
            settleAt = Date().addingTimeInterval(max(0, delay))
        }
    }

    func waitUntilSettled() async throws {
        while true {
            try Task.checkCancellation()
            let snapshot = lock.withLock { (generation, settleAt) }
            guard let deadline = snapshot.1 else { return }

            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try await Task.sleep(
                    nanoseconds: UInt64(remaining * 1_000_000_000))
                continue
            }

            let settled = lock.withLock { () -> Bool in
                guard generation == snapshot.0, settleAt == deadline else {
                    return false
                }
                settleAt = nil
                return true
            }
            if settled { return }
        }
    }
}
