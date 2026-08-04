import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Pinned focus submitter")
struct PinnedFocusSubmitterTests {

    @Test("A pinned delivery is focused before the submit")
    func focusesPinnedSessionBeforeSubmit() async {
        let focuser = MockAgentFocuser()
        let wrapped = MockTurnSubmitter()
        let submitter = PinnedFocusSubmitter(
            focuser: focuser,
            pinnedDelivery: {
                PinnedDelivery(
                    bundleID: "com.googlecode.iterm2",
                    processIdentifier: 42,
                    ttyDevice: 5)
            },
            wrapping: wrapped)

        await submitter.submitTurn()

        #expect(
            focuser.requests
                == [
                    MockAgentFocuser.Request(
                        bundleID: "com.googlecode.iterm2",
                        processIdentifier: 42,
                        ttyDevice: 5)
                ])
        #expect(wrapped.submitCount == 1)
    }

    @Test("Without a pinned delivery the submit passes straight through")
    func passesThroughWithoutPinnedDelivery() async {
        let focuser = MockAgentFocuser()
        let wrapped = MockTurnSubmitter()
        let submitter = PinnedFocusSubmitter(
            focuser: focuser,
            pinnedDelivery: { nil },
            wrapping: wrapped)

        await submitter.submitTurn()

        #expect(focuser.requests.isEmpty)
        #expect(wrapped.submitCount == 1)
    }
}
