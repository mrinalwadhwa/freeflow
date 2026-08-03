import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Kokoro speech synthesizer")
struct KokoroSpeechSynthesizerTests {

    private func makeMissingDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-missing-\(UUID().uuidString)")
    }

    @Test("Speaking without a model pack returns promptly")
    func missingPackReturnsPromptly() async {
        // Model load fails (no weights); speak must swallow the failure
        // and return so the read session ends instead of hanging.
        let synthesizer = KokoroSpeechSynthesizer(
            modelDirectory: makeMissingDirectory(),
            g2pResourcesDirectory: makeMissingDirectory())
        await synthesizer.speak("This has nowhere to go.")
    }

    @Test("Stopping while idle is safe")
    func stopWhileIdleIsSafe() {
        let synthesizer = KokoroSpeechSynthesizer(
            modelDirectory: makeMissingDirectory(),
            g2pResourcesDirectory: makeMissingDirectory())
        synthesizer.stopSpeaking()
        synthesizer.stopSpeaking()
    }

    @Test("Speaking empty text returns immediately")
    func emptyTextReturnsImmediately() async {
        let synthesizer = KokoroSpeechSynthesizer(
            modelDirectory: makeMissingDirectory(),
            g2pResourcesDirectory: makeMissingDirectory())
        await synthesizer.speak("   \n ")
    }

    @Test("Playback queues its first buffer before starting")
    func playbackQueuesBeforeStarting() throws {
        let player = RecordingPCMChunkPlayer()
        let playback = PCMChunkPlayback(player: player)

        try playback.schedule(samples: [0.1, 0.2])

        #expect(player.events == [.scheduled, .started])
        playback.stop()
    }
}

private final class RecordingPCMChunkPlayer: PCMChunkPlaying,
    @unchecked Sendable
{
    enum Event: Equatable {
        case scheduled
        case started
        case stopped
    }

    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 24_000,
        channels: 1,
        interleaved: false)
    private(set) var events: [Event] = []

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) {
        events.append(.scheduled)
    }

    func start() throws {
        events.append(.started)
    }

    func stop() {
        events.append(.stopped)
    }
}
