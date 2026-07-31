import Foundation
import Testing

@testable import UnrambleKit

@Suite("Audio input device transition gate")
struct AudioInputDeviceTransitionGateTests {
    @Test("A newer device notification extends the settling boundary")
    func coalescesNotificationBursts() async throws {
        let gate = AudioInputDeviceTransitionGate()
        gate.begin(settleAfter: 0.04)
        let clock = ContinuousClock()
        let started = clock.now

        let waiter = Task {
            try await gate.waitUntilSettled()
        }
        try await Task.sleep(nanoseconds: 25_000_000)
        gate.begin(settleAfter: 0.04)
        try await waiter.value

        #expect(clock.now - started >= .milliseconds(55))
    }

    @Test("A cancelled recording start does not remain stuck in probation")
    func cancellationStopsWaiting() async {
        let gate = AudioInputDeviceTransitionGate()
        gate.begin(settleAfter: 10)
        let waiter = Task {
            try await gate.waitUntilSettled()
        }

        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("Expected device-settle wait to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
