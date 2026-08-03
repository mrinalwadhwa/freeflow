import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import UnrambleKit

#if canImport(AVFoundation) && canImport(CoreAudio)
    @Suite("Direct-device AUHAL capture")
    struct AUHALAudioCaptureProviderTests {
        @Test("A straddling callback returns exactly the pre-release audio")
        func releaseBoundaryExcludesSuffix() async throws {
            let fixture = try Fixture()
            let owner = AudioCaptureOwner.dictation(DictationSessionID())
            let start = futureHostTime()
            let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
            #expect(
                boundary.publish(
                    releaseHostTime: addingFrames(1_600, to: start)))

            try await fixture.provider.startRecording(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: boundary,
                onCaptureReady: {})
            try fixture.transport.emit(
                frameCount: 3_200,
                value: 0.25,
                hostTime: start)

            let result = try await fixture.provider.stopRecording(owner: owner)

            #expect(result.duration > 0.095)
            #expect(result.duration < 0.105)
            #expect(result.data.count > 44)
            #expect(fixture.transport.stopCount == 1)
            #expect(!fixture.provider.isRecording)
        }

        @Test("Preview and dictation share one pinned physical transport")
        func previewAndDictationShareTransport() async throws {
            let fixture = try Fixture()
            let previewOwner = AudioCaptureOwner.preview()
            let dictationOwner = AudioCaptureOwner.dictation(DictationSessionID())
            let start = futureHostTime()

            try await fixture.provider.startRecording(
                owner: previewOwner,
                configuration: .previewMetering,
                releaseBoundary: nil,
                onCaptureReady: {})
            try fixture.transport.emit(
                frameCount: 800,
                value: 0.1,
                hostTime: start)

            let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)
            #expect(
                boundary.publish(
                    releaseHostTime: addingFrames(1_600, to: start)))
            try await fixture.provider.startRecording(
                owner: dictationOwner,
                configuration: .dictation,
                releaseBoundary: boundary,
                onCaptureReady: {})
            try fixture.transport.emit(
                frameCount: 800,
                value: 0.2,
                hostTime: addingFrames(800, to: start))

            fixture.provider.markNeedsRebuild()
            let result = try await fixture.provider.stopRecording(
                owner: dictationOwner)

            #expect(result.duration > 0.095)
            #expect(result.duration < 0.105)
            #expect(fixture.transport.startCount == 1)
            #expect(fixture.transport.stopCount == 0)
            #expect(fixture.provider.isRecording(owner: previewOwner))

            _ = try await fixture.provider.stopRecording(owner: previewOwner)
            #expect(fixture.transport.stopCount == 1)
            #expect(!fixture.provider.isRecording)
        }

        @Test("A timestamp gap fails closed and retains every captured frame")
        func timestampGapRetainsCapturedFrames() async throws {
            let fixture = try Fixture()
            let owner = AudioCaptureOwner.dictation(DictationSessionID())
            let start = futureHostTime()
            let boundary = AudioCaptureReleaseBoundary(pressHostTime: start)

            try await fixture.provider.startRecording(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: boundary,
                onCaptureReady: {})
            try fixture.transport.emit(
                frameCount: 1_600,
                value: 0.25,
                hostTime: start)
            try fixture.transport.emit(
                frameCount: 1_600,
                value: 0.25,
                hostTime: addingFrames(17_600, to: start))

            do {
                _ = try await fixture.provider.stopRecording(owner: owner)
                Issue.record("Expected timestamp coverage failure")
            } catch let error as AudioCaptureError {
                let retained = try #require(error.recoverableAudioBuffer)
                #expect(retained.data.count > 44)
                #expect(retained.duration > 0.195)
                #expect(retained.duration < 0.205)
            }
            #expect(fixture.transport.stopCount == 1)
            #expect(!fixture.provider.isRecording)
        }

        @Test("A stale owner cannot stop another owner's capture")
        func staleOwnerCannotStopCapture() async throws {
            let fixture = try Fixture()
            let owner = AudioCaptureOwner.dictation(DictationSessionID())
            let staleOwner = AudioCaptureOwner.dictation(DictationSessionID())

            try await fixture.provider.startRecording(
                owner: owner,
                configuration: .dictation,
                releaseBoundary: nil,
                onCaptureReady: {})

            await #expect(throws: AudioCaptureError.self) {
                _ = try await fixture.provider.stopRecording(owner: staleOwner)
            }
            #expect(fixture.provider.isRecording(owner: owner))
            #expect(fixture.transport.stopCount == 0)
            #expect(fixture.provider.forceReset(owner: owner))
        }

        private struct Fixture {
            let provider: AUHALAudioCaptureProvider
            let transport: FakeAUHALInputTransport
            let deviceProvider: FakeAudioInputDeviceProvider

            init() throws {
                let format = try #require(
                    AVAudioFormat(
                        commonFormat: .pcmFormatFloat32,
                        sampleRate: 16_000,
                        channels: 1,
                        interleaved: false))
                let transport = FakeAUHALInputTransport(
                    deviceID: 113,
                    format: format)
                provider = AUHALAudioCaptureProvider { deviceID in
                    #expect(deviceID == 113)
                    return transport
                }
                let deviceProvider = FakeAudioInputDeviceProvider()
                provider.setAudioDeviceProvider(deviceProvider)
                self.transport = transport
                self.deviceProvider = deviceProvider
            }
        }

        private func futureHostTime() -> UInt64 {
            AudioCaptureReleaseFence.currentHostTime()
                + AVAudioTime.hostTime(forSeconds: 1)
        }

        private func addingFrames(_ frames: Int, to hostTime: UInt64) -> UInt64 {
            hostTime
                + AVAudioTime.hostTime(
                    forSeconds: Double(frames) / 16_000)
        }
    }

    private final class FakeAUHALInputTransport: AUHALInputTransporting,
        @unchecked Sendable
    {
        let format: AVAudioFormat
        let deviceID: AudioObjectID

        private let lock = NSLock()
        private var handler:
            (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private(set) var startCount = 0
        private(set) var stopCount = 0

        init(deviceID: AudioObjectID, format: AVAudioFormat) {
            self.deviceID = deviceID
            self.format = format
        }

        func start(
            handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) throws {
            lock.withLock {
                self.handler = handler
                startCount += 1
            }
        }

        func stop() {
            lock.withLock {
                handler = nil
                stopCount += 1
            }
        }

        func emit(
            frameCount: Int,
            value: Float,
            hostTime: UInt64
        ) throws {
            let buffer = try #require(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(frameCount)))
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0..<frameCount { samples[frame] = value }
            let callback = try #require(lock.withLock { handler })
            callback(buffer, AVAudioTime(hostTime: hostTime))
        }
    }

    private final class FakeAudioInputDeviceProvider:
        AudioInputDeviceSnapshotProviding, @unchecked Sendable
    {
        var selectedDeviceID: UInt32? { 113 }
        var captureDeviceID: UInt32? { 113 }
        var isSoundFeedbackSafe: Bool { false }

        func clearSelection() {}
        func clearUnavailableCaptureSelection() {}
        func waitUntilInputDeviceSettled() async throws {}
        func micProximityForDevice(_ deviceID: UInt32?) -> MicProximity {
            .nearField
        }
        func deviceNameForDevice(_ deviceID: UInt32?) -> String? {
            "Yeti Nano"
        }
    }
#endif
