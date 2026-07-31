import Foundation

/// Runs asynchronous operations in submission order, including across
/// suspension points. Cancelling a queued caller cancels only its operation;
/// the predecessor remains owned and must drain before the queue advances.
actor AsyncSerialOperationQueue {
    private var tail: Task<Void, Never>?

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        // An unstructured Task created by an already-cancelled caller does not
        // reliably inherit that cancellation. Reject before creating the queue
        // entry so a caller cancelled prior to actor admission cannot run.
        try Task.checkCancellation()
        let predecessor = tail
        let task = Task<Value, Error> {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task {
            _ = await task.result
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
