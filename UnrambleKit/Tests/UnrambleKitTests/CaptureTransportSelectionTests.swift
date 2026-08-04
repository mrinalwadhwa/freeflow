import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Capture transport selection")
struct CaptureTransportSelectionTests {

    private final class StubTransport: AUHALInputTransporting,
        @unchecked Sendable
    {
        let format: AVAudioFormat
        let deviceID: AudioObjectID
        let name: String

        init(deviceID: AudioObjectID, name: String) {
            format = AVAudioFormat(
                standardFormatWithSampleRate: 48_000,
                channels: 1)!
            self.deviceID = deviceID
            self.name = name
        }

        func start(
            handler: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) ->
                Void
        ) throws {}

        func stop() {}
    }

    private struct BuildFailure: Error {}

    @Test("Voice processing off selects the direct transport")
    func disabledSelectsDirect() throws {
        let transport = try AUHALAudioCaptureProvider.selectTransport(
            deviceID: 7,
            voiceProcessing: false,
            makeVoiceProcessed: { _ in
                Issue.record("Voice-processed factory should not run")
                throw BuildFailure()
            },
            makeDirect: { StubTransport(deviceID: $0, name: "direct") })
        #expect((transport as? StubTransport)?.name == "direct")
        #expect(transport.deviceID == 7)
    }

    @Test("Voice processing on selects the voice-processed transport")
    func enabledSelectsVoiceProcessed() throws {
        let transport = try AUHALAudioCaptureProvider.selectTransport(
            deviceID: 7,
            voiceProcessing: true,
            makeVoiceProcessed: {
                StubTransport(deviceID: $0, name: "voice-processed")
            },
            makeDirect: { _ in
                Issue.record("Direct factory should not run")
                throw BuildFailure()
            })
        #expect((transport as? StubTransport)?.name == "voice-processed")
    }

    @Test("A failed voice-processed build falls back to direct")
    func failedVoiceProcessedFallsBack() throws {
        let transport = try AUHALAudioCaptureProvider.selectTransport(
            deviceID: 7,
            voiceProcessing: true,
            makeVoiceProcessed: { _ in throw BuildFailure() },
            makeDirect: { StubTransport(deviceID: $0, name: "direct") })
        #expect((transport as? StubTransport)?.name == "direct")
    }

    @Test("A failed direct build propagates its error")
    func failedDirectThrows() {
        #expect(throws: BuildFailure.self) {
            _ = try AUHALAudioCaptureProvider.selectTransport(
                deviceID: 7,
                voiceProcessing: true,
                makeVoiceProcessed: { _ in throw BuildFailure() },
                makeDirect: { _ in throw BuildFailure() })
        }
    }
}
