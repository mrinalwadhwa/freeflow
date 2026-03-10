import Foundation

/// Execute an async operation with a timeout. Return nil if the deadline is exceeded.
///
/// Used by context assembly to enforce per-field and total latency budgets.
/// When the timeout fires first, the operation's task is cancelled and nil is returned.
///
/// - Parameters:
///   - seconds: Maximum time in seconds to wait for the operation.
///   - operation: The async work to perform.
/// - Returns: The operation's result, or nil if the timeout expired.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            await operation()
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
