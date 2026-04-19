import Testing
import Foundation

@testable import FreeFlowKit

/// Mock polish client with configurable delay and result.
private final class DelayedPolishClient: PolishChatClient, @unchecked Sendable {
    let result: String
    let delay: TimeInterval
    let shouldThrow: Bool
    private(set) var callCount = 0

    init(result: String = "", delay: TimeInterval = 0, shouldThrow: Bool = false) {
        self.result = result
        self.delay = delay
        self.shouldThrow = shouldThrow
    }

    func complete(model: String, systemPrompt: String, userPrompt: String) async throws -> String {
        callCount += 1
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if shouldThrow { throw NSError(domain: "test", code: 1) }
        return result
    }
}

@Suite("PolishPipeline – racePolish")
struct PolishRaceTests {

    private func race(
        cloud: DelayedPolishClient,
        local: DelayedPolishClient? = nil,
        timeout: TimeInterval = 1.5
    ) async -> PolishPipeline.PolishResult {
        await PolishPipeline.racePolish(
            substituted: "test input",
            stripped: "test input",
            context: .empty,
            language: nil,
            cloudClient: cloud,
            localClient: local,
            timeout: timeout
        )
    }

    @Test("cloud wins when fast")
    func cloudWinsWhenFast() async {
        let cloud = DelayedPolishClient(result: "Cloud polished", delay: 0.1)
        let local = DelayedPolishClient(result: "Local polished", delay: 0.5)
        let result = await race(cloud: cloud, local: local, timeout: 1.5)
        #expect(result.text == "Cloud polished")
        #expect(result.source == .cloud)
    }

    @Test("local wins when cloud slow")
    func localWinsWhenCloudSlow() async {
        let cloud = DelayedPolishClient(result: "Cloud polished", delay: 2.0)
        let local = DelayedPolishClient(result: "Local polished", delay: 0.1)
        let result = await race(cloud: cloud, local: local, timeout: 0.5)
        #expect(result.text == "Local polished")
        #expect(result.source == .local)
    }

    @Test("cloud only when no local")
    func cloudOnlyWhenNoLocal() async {
        let cloud = DelayedPolishClient(result: "Cloud polished", delay: 0.1)
        let result = await race(cloud: cloud, local: nil, timeout: 1.5)
        #expect(result.text == "Cloud polished")
        #expect(result.source == .cloud)
    }

    @Test("fallback to raw when both fail")
    func fallbackToRawWhenBothFail() async {
        let cloud = DelayedPolishClient(shouldThrow: true)
        let local = DelayedPolishClient(shouldThrow: true)
        let result = await race(cloud: cloud, local: local, timeout: 1.5)
        #expect(result.text == "test input")
        #expect(result.source == .fallback)
    }

    @Test("fallback to raw when cloud slow and no local")
    func fallbackToRawWhenCloudSlowAndNoLocal() async {
        let cloud = DelayedPolishClient(result: "Cloud polished", delay: 2.0)
        let result = await race(cloud: cloud, local: nil, timeout: 0.5)
        #expect(result.text == "test input")
        #expect(result.source == .fallback)
    }

    @Test("local timeout prevents hang when local is slow")
    func localTimeoutPreventsHang() async {
        // Cloud times out at 0.3s, local takes 10s (simulating thermal throttle).
        // racePolish should not wait 10s — it should cap the local wait.
        let cloud = DelayedPolishClient(result: "Cloud polished", delay: 2.0)
        let local = DelayedPolishClient(result: "Local polished", delay: 10.0)
        let start = Date()
        let result = await race(cloud: cloud, local: local, timeout: 0.3)
        let elapsed = Date().timeIntervalSince(start)
        // Should fall back to raw within ~3-4s (cloud timeout + local timeout),
        // not hang for 10s.
        #expect(elapsed < 6.0, "Should not wait for slow local client")
        #expect(result.source == .fallback)
    }
}
