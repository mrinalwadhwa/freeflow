import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Capture transport cache")
struct CaptureTransportCacheTests {

    private final class StubTransport: AUHALInputTransporting,
        @unchecked Sendable
    {
        let format: AVAudioFormat
        let deviceID: AudioObjectID

        init(deviceID: AudioObjectID) {
            format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1)!
            self.deviceID = deviceID
        }

        func start(
            handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) ->
                Void
        ) throws {}

        func stop() {}
    }

    private struct BuildFailure: Error {}

    @Test("A matching device and kind reuses the built transport")
    func reusesMatchingTransport() throws {
        let cache = CaptureTransportCache(isDeviceAlive: { _ in true })
        var builds = 0
        let build: (AudioObjectID, Bool) throws ->
            any AUHALInputTransporting = { deviceID, _ in
                builds += 1
                return StubTransport(deviceID: deviceID)
            }

        let first = try cache.transport(
            deviceID: 7, voiceProcessing: true, build: build)
        let second = try cache.transport(
            deviceID: 7, voiceProcessing: true, build: build)

        #expect(builds == 1)
        #expect(first as? StubTransport === second as? StubTransport)
    }

    @Test("A different device rebuilds")
    func rebuildsForNewDevice() throws {
        let cache = CaptureTransportCache(isDeviceAlive: { _ in true })
        var builds = 0
        let build: (AudioObjectID, Bool) throws ->
            any AUHALInputTransporting = { deviceID, _ in
                builds += 1
                return StubTransport(deviceID: deviceID)
            }

        _ = try cache.transport(
            deviceID: 7, voiceProcessing: true, build: build)
        let second = try cache.transport(
            deviceID: 8, voiceProcessing: true, build: build)

        #expect(builds == 2)
        #expect(second.deviceID == 8)
    }

    @Test("A changed transport kind rebuilds")
    func rebuildsForNewKind() throws {
        let cache = CaptureTransportCache(isDeviceAlive: { _ in true })
        var builds = 0
        let build: (AudioObjectID, Bool) throws ->
            any AUHALInputTransporting = { deviceID, _ in
                builds += 1
                return StubTransport(deviceID: deviceID)
            }

        _ = try cache.transport(
            deviceID: 7, voiceProcessing: true, build: build)
        _ = try cache.transport(
            deviceID: 7, voiceProcessing: false, build: build)

        #expect(builds == 2)
    }

    @Test("A dead device rebuilds")
    func rebuildsForDeadDevice() throws {
        let cache = CaptureTransportCache(isDeviceAlive: { _ in false })
        var builds = 0
        let build: (AudioObjectID, Bool) throws ->
            any AUHALInputTransporting = { deviceID, _ in
                builds += 1
                return StubTransport(deviceID: deviceID)
            }

        _ = try cache.transport(
            deviceID: 7, voiceProcessing: true, build: build)
        _ = try cache.transport(
            deviceID: 7, voiceProcessing: true, build: build)

        #expect(builds == 2)
    }

    @Test("A failed build leaves the previous entry reusable")
    func failedBuildKeepsPreviousEntry() throws {
        let cache = CaptureTransportCache(isDeviceAlive: { _ in true })

        _ = try cache.transport(
            deviceID: 7,
            voiceProcessing: true,
            build: { deviceID, _ in StubTransport(deviceID: deviceID) })
        #expect(throws: BuildFailure.self) {
            _ = try cache.transport(
                deviceID: 8,
                voiceProcessing: true,
                build: { _, _ in throw BuildFailure() })
        }
        var rebuilt = false
        _ = try cache.transport(
            deviceID: 7,
            voiceProcessing: true,
            build: { deviceID, _ in
                rebuilt = true
                return StubTransport(deviceID: deviceID)
            })

        #expect(rebuilt == false)
    }
}
