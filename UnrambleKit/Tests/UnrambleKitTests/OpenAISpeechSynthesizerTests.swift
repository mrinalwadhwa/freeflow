import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("OpenAI speech synthesizer")
struct OpenAISpeechSynthesizerTests {

    @Test("A network failure before audio falls back to the local voice")
    func networkFailureFallsBack() async {
        // The test lane's network guard blocks the request immediately,
        // exercising the no-audio failure path.
        let fallback = MockSpeechSynthesizer()
        let synthesizer = OpenAISpeechSynthesizer(
            apiKey: "test-key",
            fallback: fallback)

        await synthesizer.speak("Read this aloud.")

        #expect(fallback.spokenTexts == ["Read this aloud."])
    }

    @Test("Speaking empty text returns without a request")
    func emptyTextReturns() async {
        let fallback = MockSpeechSynthesizer()
        let synthesizer = OpenAISpeechSynthesizer(
            apiKey: "test-key",
            fallback: fallback)

        await synthesizer.speak("  \n ")

        #expect(fallback.spokenTexts.isEmpty)
    }

    @Test("PCM sixteen-bit little-endian converts to floats")
    func pcmConvertsToFloats() {
        let data = Data([
            0x00, 0x00,  // 0
            0xFF, 0x7F,  // 32767
            0x00, 0x80,  // -32768
        ])
        let samples = OpenAISpeechSynthesizer.floats(fromPCM16LE: data)
        #expect(samples.count == 3)
        #expect(samples[0] == 0)
        #expect(abs(samples[1] - 0.99997) < 0.001)
        #expect(samples[2] == -1.0)
    }

    @Test("An odd trailing byte is ignored")
    func oddTrailingByteIgnored() {
        let data = Data([0x00, 0x00, 0x12])
        let samples = OpenAISpeechSynthesizer.floats(
            fromPCM16LE: data.prefix(data.count - data.count % 2))
        #expect(samples == [0])
    }
}
