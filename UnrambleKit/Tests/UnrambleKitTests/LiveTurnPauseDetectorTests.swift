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
        let sampleCount = bytes / 2
        var data = Data(capacity: bytes)
        for _ in 0..<sampleCount {
            withUnsafeBytes(of: Int16(0x4000).littleEndian) {
                data.append(contentsOf: $0)
            }
        }
        return data
    }

    @Test("Silence crossing the pause emits one pause signal")
    func silenceCrossingPauseEmitsOnce() {
        var detector = LiveTurnPauseDetector(pauseSeconds: 0.1)

        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            == [.pause])
        #expect(detector.observe(chunk: silence(1600), threshold: threshold)
            .isEmpty)
    }

    @Test("Speech after a fired pause re-arms and signals audible speech")
    func speechAfterPauseRearms() {
        var detector = LiveTurnPauseDetector(pauseSeconds: 0.1)

        #expect(detector.observe(chunk: silence(3200), threshold: threshold)
            == [.pause])
        #expect(detector.observe(chunk: speech(640), threshold: threshold)
            == [.audibleSpeech])
        #expect(detector.observe(chunk: silence(3200), threshold: threshold)
            == [.pause])
    }

    @Test("The start of a speech run signals audible speech once")
    func speechRunStartSignalsOnce() {
        var detector = LiveTurnPauseDetector(pauseSeconds: 0.1)

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
        var detector = LiveTurnPauseDetector(pauseSeconds: 0.1)

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

    @Test("An empty chunk emits nothing")
    func emptyChunkEmitsNothing() {
        var detector = LiveTurnPauseDetector(pauseSeconds: 0.1)
        #expect(detector.observe(chunk: Data(), threshold: threshold).isEmpty)
    }

    @Test("Reset forgets accumulated silence")
    func resetForgetsSilence() {
        var detector = LiveTurnPauseDetector(pauseSeconds: 0.1)

        #expect(detector.observe(chunk: silence(3000), threshold: threshold)
            .isEmpty)
        detector.reset()
        #expect(detector.observe(chunk: silence(3000), threshold: threshold)
            .isEmpty)
        #expect(detector.observe(chunk: silence(200), threshold: threshold)
            == [.pause])
    }
}
