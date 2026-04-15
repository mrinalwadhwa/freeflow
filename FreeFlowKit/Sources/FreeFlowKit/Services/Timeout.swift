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

/// Race an async operation against a timeout in a detached context.
///
/// Runs both the operation and a sleep timer as children of a single
/// detached `TaskGroup`. When one finishes first, `cancelAll()` cancels
/// the other — preventing leaked timeout sleeps or orphaned workers.
///
/// Use this instead of spawning two independent `Task.detached` blocks
/// with an `NSLock` guard, which leaks the losing task.
///
/// - Parameters:
///   - seconds: Maximum time to wait.
///   - operation: The async work. Receives the parent task's cancellation.
/// - Returns: The operation's result, or nil if the timeout expired.
func detachedWithTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    await Task.detached {
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
    }.value
}
