import Foundation

/// Intercept spoken meta-commands and recognizer noise before they
/// inject.
///
/// Decorates the pipeline's `TextInjecting` the way `InjectionRecorder`
/// does, one layer further out: while a call turn is completing, the
/// finished utterance is interpreted first, and a meta-command is held
/// for the call coordinator instead of being injected — so "hang up"
/// never lands as text in the agent's prompt. A degenerate transcript —
/// the looping sentences a recognizer invents from minutes of marginal
/// audio — is vetoed the same way; the coordinator sees an empty
/// injection and keeps listening. Outside calls every injection passes
/// straight through, so ordinary dictation never pays for
/// interpretation and can never trigger a command or a veto.
public final class CallCommandGate: TextInjecting, CallCommandGating,
    @unchecked Sendable
{

    private let wrapped: any TextInjecting
    private let interpreter: any MetaCommandInterpreting
    private let isCallTurnActive: @Sendable () -> Bool
    private let lock = NSLock()
    private var pending: CallMetaCommand?

    public init(
        interpreter: any MetaCommandInterpreting,
        isCallTurnActive: @escaping @Sendable () -> Bool,
        wrapping wrapped: any TextInjecting
    ) {
        self.interpreter = interpreter
        self.isCallTurnActive = isCallTurnActive
        self.wrapped = wrapped
    }

    public func inject(text: String, into context: AppContext) async throws {
        guard isCallTurnActive() else {
            try await wrapped.inject(text: text, into: context)
            return
        }
        if let command = await interpreter.interpret(text) {
            lock.withLock { pending = command }
            return
        }
        if DegenerateTranscriptDetector.isDegenerate(text) {
            Log.debug("[Call] degenerate transcript vetoed")
            return
        }
        try await wrapped.inject(text: text, into: context)
    }

    public func takePendingCommand() async -> CallMetaCommand? {
        lock.withLock {
            let command = pending
            pending = nil
            return command
        }
    }

    public func reset() async {
        lock.withLock { pending = nil }
    }
}
