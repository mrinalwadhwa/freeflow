import Foundation

/// Guard against double-resume when bridging callback-based recognition
/// APIs to Swift concurrency.
///
/// `SFSpeechRecognizer.recognitionTask(with:resultHandler:)` can fire
/// its callback multiple times: partial results, a final result, and
/// sometimes an error after the final result. Wrapping it in a bare
/// `withCheckedThrowingContinuation` causes undefined behavior if the
/// continuation resumes more than once.
///
/// This helper ensures the continuation resumes exactly once, ignoring
/// any subsequent callbacks.
public enum SafeRecognitionContinuation {

    /// Bridge a callback-based recognition API to async/await.
    ///
    /// - Parameter body: Receives a handler `(String?, Error?) -> Void`.
    ///   Call the handler with `(text, nil)` to deliver a result, or
    ///   `(nil, error)` to deliver an error. Calls with `(nil, nil)` are
    ///   treated as partial results and skipped. Only the first non-nil
    ///   delivery resumes the continuation; subsequent calls are ignored.
    /// - Returns: The recognized text.
    public static func run(
        _ body: @escaping (@escaping @Sendable (String?, (any Error)?) -> Void) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            body { text, error in
                lock.lock()
                guard !hasResumed else {
                    lock.unlock()
                    return
                }

                if let error {
                    hasResumed = true
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                guard let text else {
                    lock.unlock()
                    return
                }
                hasResumed = true
                lock.unlock()
                continuation.resume(returning: text)
            }
        }
    }
}
