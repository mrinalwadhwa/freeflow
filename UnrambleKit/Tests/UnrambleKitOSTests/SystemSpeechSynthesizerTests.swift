import Foundation
import Testing

@testable import UnrambleKit

@Suite("System speech synthesizer")
struct SystemSpeechSynthesizerTests {

    @Test("Stop resumes a speak call promptly")
    func stopResumesSpeak() async {
        // Stop must resume the waiting speak call even when the utterance
        // has not started speaking yet, so the read session can never hang
        // on a stopped utterance. A hang here fails the suite's time limit.
        let synthesizer = SystemSpeechSynthesizer()
        let speaking = Task {
            await synthesizer.speak(
                String(repeating: "a long sentence to read aloud. ", count: 50))
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        synthesizer.stopSpeaking()
        await speaking.value
    }

    @Test("Speaking empty text returns immediately")
    func emptyTextReturnsImmediately() async {
        let synthesizer = SystemSpeechSynthesizer()
        await synthesizer.speak("   \n ")
    }
}
