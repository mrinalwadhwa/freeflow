import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Pinned focus injector")
struct PinnedFocusInjectorTests {

    private let pinnedContext = AppContext(
        bundleID: "com.googlecode.iterm2",
        appName: "iTerm2",
        windowTitle: "claude",
        processIdentifier: 111)

    @Test("During a call, delivery focuses and retargets the context")
    func focusesAndRetargetsBeforeInjection() async throws {
        let focuser = MockAgentFocuser()
        let base = MockTextInjector()
        let provider = MockAppContextProvider(context: pinnedContext)
        let delivery = PinnedDelivery(
            bundleID: "com.googlecode.iterm2",
            processIdentifier: 111,
            ttyDevice: 5)
        let injector = PinnedFocusInjector(
            focuser: focuser,
            contextProvider: provider,
            pinnedDelivery: { delivery },
            wrapping: base)

        // The captured context says the user was elsewhere; the
        // forwarded context must describe the refocused pane.
        try await injector.inject(text: "Run the tests.", into: .stub)

        #expect(
            focuser.requests == [
                MockAgentFocuser.Request(
                    bundleID: "com.googlecode.iterm2",
                    processIdentifier: 111,
                    ttyDevice: 5)
            ])
        #expect(base.lastInjectedText == "Run the tests.")
        #expect(
            base.injections.first?.context.bundleID
                == "com.googlecode.iterm2")
    }

    @Test("Outside calls, text passes through with its own context")
    func passesThroughWithoutDelivery() async throws {
        let focuser = MockAgentFocuser()
        let base = MockTextInjector()
        let provider = MockAppContextProvider(context: pinnedContext)
        let injector = PinnedFocusInjector(
            focuser: focuser,
            contextProvider: provider,
            pinnedDelivery: { nil },
            wrapping: base)

        try await injector.inject(text: "Plain dictation.", into: .stub)

        #expect(focuser.requests.isEmpty)
        #expect(base.lastInjectedText == "Plain dictation.")
        #expect(
            base.injections.first?.context.bundleID
                == AppContext.stub.bundleID)
    }
}
