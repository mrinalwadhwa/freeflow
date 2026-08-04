import Foundation

/// The pinned session's delivery address: the terminal application
/// and the exact pane by tty.
public struct PinnedDelivery: Equatable, Sendable {
    public let bundleID: String
    public let processIdentifier: Int32?
    public let ttyDevice: Int32?

    public init(
        bundleID: String,
        processIdentifier: Int32?,
        ttyDevice: Int32?
    ) {
        self.bundleID = bundleID
        self.processIdentifier = processIdentifier
        self.ttyDevice = ttyDevice
    }
}

/// Focus the pinned session at the instant of injection.
///
/// Focusing earlier loses races: transcription runs between the
/// turn's endpoint and its injection, and in that window macOS can
/// hand focus back to wherever the user wandered. Running the
/// focus handshake here leaves only milliseconds between verified
/// focus and the paste. Outside calls the closure returns nil and
/// text passes straight through.
public final class PinnedFocusInjector: TextInjecting, @unchecked Sendable {

    private let wrapped: any TextInjecting
    private let focuser: any AgentFocusing
    private let contextProvider: any AppContextProviding
    private let pinnedDelivery: @Sendable () async -> PinnedDelivery?

    public init(
        focuser: any AgentFocusing,
        contextProvider: any AppContextProviding,
        pinnedDelivery: @escaping @Sendable () async -> PinnedDelivery?,
        wrapping wrapped: any TextInjecting
    ) {
        self.focuser = focuser
        self.contextProvider = contextProvider
        self.pinnedDelivery = pinnedDelivery
        self.wrapped = wrapped
    }

    public func inject(text: String, into context: AppContext) async throws {
        guard let delivery = await pinnedDelivery() else {
            try await wrapped.inject(text: text, into: context)
            return
        }
        await focuser.focusSession(
            bundleID: delivery.bundleID,
            processIdentifier: delivery.processIdentifier,
            ttyDevice: delivery.ttyDevice)
        // The captured context describes wherever the user was when
        // the turn was transcribed — its strategy and focused element
        // could deliver the text there via Accessibility, no focus
        // needed. Re-read the context so the injection targets the
        // pane the handshake just focused.
        let pinnedContext = await contextProvider.readContext()
        try await wrapped.inject(text: text, into: pinnedContext)
    }
}
