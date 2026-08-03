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
}
