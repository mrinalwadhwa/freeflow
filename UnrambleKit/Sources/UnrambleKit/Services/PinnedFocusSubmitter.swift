import Foundation

/// Focus the pinned session at the instant of submission.
///
/// Injection focuses the pinned pane under its own handshake, but
/// transcription-to-submit spans enough time for a clicking user to
/// take focus back — live testing produced a turn that pasted into
/// the agent's prompt and then pressed Return in another window,
/// leaving the text sitting unsubmitted. Re-running the focus
/// handshake here leaves only milliseconds between verified focus
/// and the keypress. Without a pinned delivery the submit passes
/// straight through.
public struct PinnedFocusSubmitter: TurnSubmitting {

    private let focuser: any AgentFocusing
    private let pinnedDelivery: @Sendable () async -> PinnedDelivery?
    private let wrapped: any TurnSubmitting

    public init(
        focuser: any AgentFocusing,
        pinnedDelivery: @escaping @Sendable () async -> PinnedDelivery?,
        wrapping wrapped: any TurnSubmitting
    ) {
        self.focuser = focuser
        self.pinnedDelivery = pinnedDelivery
        self.wrapped = wrapped
    }

    public func submitTurn() async {
        if let delivery = await pinnedDelivery() {
            await focuser.focusSession(
                bundleID: delivery.bundleID,
                processIdentifier: delivery.processIdentifier,
                ttyDevice: delivery.ttyDevice)
        }
        await wrapped.submitTurn()
    }
}
