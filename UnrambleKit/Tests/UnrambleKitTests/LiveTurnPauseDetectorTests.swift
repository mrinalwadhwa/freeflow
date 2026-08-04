import Foundation
import Testing

@testable import UnrambleKit

@Suite("Live turn pause detector")
struct LiveTurnPauseDetectorTests {

    private let threshold: Float = 0.0005

    /// One tenth of a second of silence or speech at 16 kHz 16-bit
    /// mono is 3200 bytes.
    private func silence(_ bytes: Int) -> Data {
        Data(count: bytes)
    }

    private func speech(_ bytes: Int) -> Data {
        tone(bytes, amplitude: 0x4000)
    }

    private func tone(_ bytes: Int, amplitude: Int16) -> Data {
        let sampleCount = bytes / 2
        var data = Data(capacity: bytes)
        for _ in 0..<sampleCount {
            withUnsafeBytes(of: amplitude.littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    @Test("Silence crossing the pause emits one pause signal")
    func silenceCrossingPauseEmitsOnce() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0)

        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            == [.pause])
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
    }

    @Test("Speech after a fired pause re-arms and signals audible speech")
    func speechAfterPauseRearms() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0)

        #expect(detector.observe(chunk: silence(3200), threshold: threshold)
            == [.pause])
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
        #expect(detector.observe(chunk: silence(3200), threshold: threshold)
            == [.pause])
    }

    @Test("The start of a speech run signals audible speech once")
    func speechRunStartSignalsOnce() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0)

        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
    }

    @Test("A chunk containing speech resets the pause window")
    func mixedChunkResetsPauseWindow() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0)

        // Nearly a full pause of silence, then speech resets the run.
        #expect(detector.observe(chunk: silence(3000), threshold: threshold)
            .isEmpty)
        var mixed = speech(640)
        mixed.append(silence(640))
        #expect(detector.observe(chunk: mixed, threshold: threshold)
            == [.audibleSpeech])

        // The pause needs its full stretch of silence again.
        #expect(detector.observe(chunk: silence(1920), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(640), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(640), threshold: threshold)
            == [.pause])
    }

    @Test("An impulsive burst never signals audible speech")
    func impulsiveBurstStaysSilent() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0.1)

        // A knock: 20 ms of energy between stretches of silence. It
        // resets the pause window but never sustains into speech.
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            == [.pause])
    }

    @Test("A sustained speech run signals once at the crossing")
    func sustainedRunSignalsAtCrossing() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0.04)

        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            .isEmpty)
    }

    @Test("Silence between bursts resets the sustain accumulation")
    func silenceResetsSustainAccumulation() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0.04)

        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(320), threshold: threshold)
            .isEmpty)
        // Two separate bursts never add up; only a continuous run
        // crosses the sustain window.
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
    }

    @Test("An ambient dip does not reclassify room tone as speech")
    func ambientDipKeepsRoomToneSilent() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 10, sustainSeconds: 0.04)

        // Steady room tone becomes the floor.
        for _ in 0..<5 {
            #expect(
                detector.observe(
                    chunk: tone(1280, amplitude: 655),
                    threshold: threshold
                ).isEmpty)
        }
        // One anomalous quiet chunk must not redefine the room…
        #expect(
            detector.observe(
                chunk: tone(1280, amplitude: 33),
                threshold: threshold
            ).isEmpty)
        // …so the tone that follows is still ambience, not speech.
        for _ in 0..<5 {
            #expect(
                detector.observe(
                    chunk: tone(1280, amplitude: 655),
                    threshold: threshold
                ).isEmpty)
        }
        // Real speech still crosses immediately.
        #expect(
            detector.observe(chunk: speech(1280), threshold: threshold)
                == [.audibleSpeech])
    }

    @Test("A fluctuating residual stays ambience and still pauses")
    func fluctuatingResidualStaysAmbient() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.5, sustainSeconds: 0.04)

        // Echo-cancelled playback leaves a hash whose swells run
        // several times its own dips. A floor that chased the dips
        // would classify every swell as speech; the turn would never
        // pause and the recognizer would hallucinate from the hash.
        var signals: [TurnSignal] = []
        for _ in 0..<10 {
            for amplitude in [Int16(655), 66, 262] {
                signals += detector.observe(
                    chunk: tone(1280, amplitude: amplitude),
                    threshold: threshold)
            }
        }
        #expect(signals == [.pause])

        // Real speech still crosses immediately.
        #expect(
            detector.observe(chunk: speech(1280), threshold: threshold)
                == [.audibleSpeech])
    }

    @Test("A configured final pause re-fires once after the hold window")
    func finalPauseRefiresOnce() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.05, sustainSeconds: 0, finalPauseSeconds: 0.1)

        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            == [.pause])
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            == [.pause])
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)

        // Speech re-arms both crossings.
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
        #expect(detector.observe(chunk: silence(3200), threshold: threshold)
            == [.pause, .pause])
    }

    @Test("An empty chunk emits nothing")
    func emptyChunkEmitsNothing() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0)
        #expect(detector.observe(chunk: Data(), threshold: threshold).isEmpty)
    }

    @Test("Reset forgets accumulated silence")
    func resetForgetsSilence() {
        var detector = LiveTurnPauseDetector(
            pauseSeconds: 0.1, sustainSeconds: 0)

        #expect(detector.observe(chunk: silence(3000), threshold: threshold)
            .isEmpty)
        detector.reset()
        #expect(detector.observe(chunk: silence(3000), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(200), threshold: threshold)
            == [.pause])
    }
}
