import Foundation
import Testing

@testable import VoiceKit

@Suite("Accessibility permission provider")
struct PermissionProviderTests {

    // MARK: - Initialization

    @Test("Provider initializes without error")
    func initializesCleanly() {
        let provider = AccessibilityPermissionProvider()
        _ = provider  // Confirm no crash on init
    }

    // MARK: - Microphone (Stubbed)

    @Test("Microphone check returns notDetermined (stubbed)")
    func microphoneCheckStubbed() {
        let provider = AccessibilityPermissionProvider()
        let state = provider.checkMicrophone()
        #expect(state == .notDetermined)
    }

    @Test("Microphone request returns notDetermined (stubbed)")
    func microphoneRequestStubbed() async {
        let provider = AccessibilityPermissionProvider()
        let state = await provider.requestMicrophone()
        #expect(state == .notDetermined)
    }

    // MARK: - Accessibility Check

    @Test("Accessibility check returns a valid permission state")
    func accessibilityCheckReturnsValidState() {
        let provider = AccessibilityPermissionProvider()
        let state = provider.checkAccessibility()
        // In CI or test environments, accessibility is typically not granted.
        // We just verify it returns one of the valid states rather than crashing.
        #expect(state == .granted || state == .denied)
    }

    @Test("Accessibility check is consistent across repeated calls")
    func accessibilityCheckConsistent() {
        let provider = AccessibilityPermissionProvider()
        let first = provider.checkAccessibility()
        let second = provider.checkAccessibility()
        let third = provider.checkAccessibility()
        #expect(first == second)
        #expect(second == third)
    }

    @Test("Refresh returns the same state as check")
    func refreshMatchesCheck() {
        let provider = AccessibilityPermissionProvider()
        let checked = provider.checkAccessibility()
        let refreshed = provider.refreshAccessibility()
        #expect(checked == refreshed)
    }

    // MARK: - Protocol Conformance

    @Test("Provider conforms to PermissionProviding")
    func conformsToProtocol() {
        let provider = AccessibilityPermissionProvider()
        let _: any PermissionProviding = provider
    }

    @Test("Provider is Sendable")
    func isSendable() {
        let provider = AccessibilityPermissionProvider()
        let _: any Sendable = provider
    }

    // MARK: - Thread Safety

    @Test("Concurrent accessibility checks do not crash")
    func concurrentAccessibilityChecks() async {
        let provider = AccessibilityPermissionProvider()

        await withTaskGroup(of: PermissionState.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    provider.checkAccessibility()
                }
            }

            var states: [PermissionState] = []
            for await state in group {
                states.append(state)
            }

            // All concurrent reads should return the same value
            let unique = Set(states)
            #expect(unique.count == 1)
        }
    }

    // MARK: - Wait For Accessibility (Timeout Behavior)

    @Test("Wait for accessibility returns within timeout when already granted")
    func waitReturnsQuicklyIfGranted() async {
        let provider = AccessibilityPermissionProvider()
        let currentState = provider.checkAccessibility()

        // If already granted, should return almost immediately
        if currentState == .granted {
            let result = await provider.waitForAccessibility(
                pollingInterval: 0.1,
                timeout: 1.0
            )
            #expect(result == .granted)
        }
    }

    @Test("Wait for accessibility respects short timeout")
    func waitRespectsTimeout() async {
        let provider = AccessibilityPermissionProvider()
        let currentState = provider.checkAccessibility()

        // If not granted, wait should respect the timeout and not block forever
        if currentState == .denied {
            let start = Date()
            let result = await provider.waitForAccessibility(
                pollingInterval: 0.05,
                timeout: 0.2
            )
            let elapsed = Date().timeIntervalSince(start)

            #expect(result == .denied)
            // Should complete within a reasonable margin of the timeout
            #expect(elapsed < 1.0)
        }
    }

    // MARK: - Mock Comparison

    @Test("Real provider and mock provider share the same protocol interface")
    func realAndMockShareProtocol() {
        let real: any PermissionProviding = AccessibilityPermissionProvider()
        let mock: any PermissionProviding = MockPermissionProvider()

        // Both conform and can be used interchangeably
        _ = real.checkAccessibility()
        _ = mock.checkAccessibility()
    }
}
