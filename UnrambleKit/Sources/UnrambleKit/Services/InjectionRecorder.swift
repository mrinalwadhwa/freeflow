import Foundation

/// Record what the wrapped injector delivers.
///
/// Decorates the pipeline's `TextInjecting` so the conversation call
/// can observe the exact text a completed turn injected — without the
/// pipeline knowing calls exist. Only a successful injection is
/// recorded; a throwing strategy leaves the record empty.
public final class InjectionRecorder: TextInjecting, InjectionObserving,
    @unchecked Sendable
{

    private let wrapped: any TextInjecting
    private let lock = NSLock()
    private var _lastInjectedText: String?

    public init(wrapping wrapped: any TextInjecting) {
        self.wrapped = wrapped
    }

    public func inject(text: String, into context: AppContext) async throws {
        try await wrapped.inject(text: text, into: context)
        lock.withLock { _lastInjectedText = text }
    }

    public func reset() async {
        lock.withLock { _lastInjectedText = nil }
    }

    public func lastInjectedText() async -> String? {
        lock.withLock { _lastInjectedText }
    }
}
