import Foundation

/// Report what the dictation pipeline injected, so the conversation
/// call can tell a delivered turn from an empty one and anchor the
/// response watch on the exact injected text.
public protocol InjectionObserving: Sendable {

    /// Forget any previously recorded injection.
    func reset() async

    /// The text injected since the last `reset()`, or nil when
    /// nothing was injected.
    func lastInjectedText() async -> String?
}
