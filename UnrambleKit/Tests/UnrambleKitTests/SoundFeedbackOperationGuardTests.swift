import Foundation
import Testing

@testable import UnrambleKit

@Suite("Sound feedback operation guard")
struct SoundFeedbackOperationGuardTests {
    @Test("Returns nil when the audio operation succeeds")
    func successfulOperation() {
        var completed = false

        let failure = SoundFeedbackOperationGuard.run {
            completed = true
        }

        #expect(completed)
        #expect(failure == nil)
    }

    @Test("Catches an Objective-C audio-route exception")
    func catchesRouteException() {
        let failure = SoundFeedbackOperationGuard.run {
            NSException(
                name: .internalInconsistencyException,
                reason: "player started when in a disconnected state"
            ).raise()
        }

        #expect(
            failure == "player started when in a disconnected state")
    }
}
