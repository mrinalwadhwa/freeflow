import Foundation
import Testing

@testable import VoiceKit

@Suite("AudioLevelAnalyzer")
struct AudioLevelAnalyzerTests {

    // MARK: - Helpers

    /// Build a WAV-encoded AudioBuffer from raw 16-bit PCM samples.
    private func makeBuffer(samples: [Int16], sampleRate: Int = 16000) -> AudioBuffer {
        var pcmData = Data(capacity: samples.count * 2)
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }

        let wavData = WAVEncoder.encode(
            pcmData: pcmData,
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16
        )

        let duration = WAVEncoder.duration(
            byteCount: pcmData.count,
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16
        )

        return AudioBuffer(
            data: wavData,
            duration: duration,
            sampleRate: sampleRate,
            channels: 1,
            bitsPerSample: 16
        )
    }

    // MARK: - RMS level

    @Test("Empty buffer returns zero RMS")
    func emptyBufferReturnsZero() {
        let rms = AudioLevelAnalyzer.rmsLevel(of: .empty)
        #expect(rms == 0.0)
    }

    @Test("All-zero samples return zero RMS")
    func silentSamplesReturnZero() {
        let samples = [Int16](repeating: 0, count: 1600)
        let buffer = makeBuffer(samples: samples)
        let rms = AudioLevelAnalyzer.rmsLevel(of: buffer)
        #expect(rms == 0.0)
    }

    @Test("Full-scale samples return RMS near 1.0")
    func fullScaleReturnsOne() {
        // Alternating max positive and max negative gives RMS ≈ 1.0.
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? Int16.max : Int16.min + 1 }
        let buffer = makeBuffer(samples: samples)
        let rms = AudioLevelAnalyzer.rmsLevel(of: buffer)
        #expect(rms > 0.99)
        #expect(rms <= 1.0)
    }

    @Test("Half-scale samples return RMS near 0.5")
    func halfScaleReturnsHalf() {
        let halfMax = Int16(Int16.max / 2)
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? halfMax : -halfMax }
        let buffer = makeBuffer(samples: samples)
        let rms = AudioLevelAnalyzer.rmsLevel(of: buffer)
        #expect(rms > 0.45)
        #expect(rms < 0.55)
    }

    @Test("Low-amplitude samples return small RMS")
    func lowAmplitudeReturnsSmallRMS() {
        // Samples around ±100 out of ±32767 → RMS ≈ 0.003
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? 100 : -100 }
        let buffer = makeBuffer(samples: samples)
        let rms = AudioLevelAnalyzer.rmsLevel(of: buffer)
        #expect(rms > 0.0)
        #expect(rms < 0.01)
    }

    @Test("RMS is clamped to 1.0")
    func rmsClampedToOne() {
        // Even with all samples at Int16.min (slightly larger magnitude
        // than Int16.max), the result should not exceed 1.0.
        let samples = [Int16](repeating: Int16.min, count: 1600)
        let buffer = makeBuffer(samples: samples)
        let rms = AudioLevelAnalyzer.rmsLevel(of: buffer)
        #expect(rms <= 1.0)
    }

    @Test("Buffer with only WAV header and no PCM data returns zero")
    func headerOnlyReturnsZero() {
        // 44-byte WAV header with no sample data.
        let wavData = WAVEncoder.encode(
            pcmData: Data(),
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )
        let buffer = AudioBuffer(data: wavData, duration: 0)
        let rms = AudioLevelAnalyzer.rmsLevel(of: buffer)
        #expect(rms == 0.0)
    }

    // MARK: - Silence detection

    @Test("Silent buffer is detected as silent")
    func silentBufferDetectedAsSilent() {
        let samples = [Int16](repeating: 0, count: 1600)
        let buffer = makeBuffer(samples: samples)
        #expect(AudioLevelAnalyzer.isSilent(buffer))
    }

    @Test("Loud buffer is not detected as silent")
    func loudBufferNotSilent() {
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? 5000 : -5000 }
        let buffer = makeBuffer(samples: samples)
        #expect(!AudioLevelAnalyzer.isSilent(buffer))
    }

    @Test("Custom threshold is respected")
    func customThreshold() {
        // Samples at ±100 → RMS ≈ 0.003
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? 100 : -100 }
        let buffer = makeBuffer(samples: samples)

        // With default threshold (0.005), these are below it → silent.
        #expect(AudioLevelAnalyzer.isSilent(buffer, threshold: 0.005))

        // With a very low threshold (0.001), they are above it → not silent.
        #expect(!AudioLevelAnalyzer.isSilent(buffer, threshold: 0.001))
    }

    @Test("Empty buffer is silent")
    func emptyBufferIsSilent() {
        #expect(AudioLevelAnalyzer.isSilent(.empty))
    }

    @Test("Near-threshold audio with very quiet speech is not silent")
    func quietSpeechNotSilent() {
        // Samples at ±600 → RMS ≈ 0.018, well above 0.005 threshold.
        let samples: [Int16] = (0..<1600).map { $0 % 2 == 0 ? 600 : -600 }
        let buffer = makeBuffer(samples: samples)
        #expect(!AudioLevelAnalyzer.isSilent(buffer))
    }

    @Test("Mixed silence and speech yields non-silent result")
    func mixedSilenceAndSpeech() {
        // 800 silent samples followed by 800 speech-level samples.
        var samples = [Int16](repeating: 0, count: 800)
        samples.append(contentsOf: (0..<800).map { $0 % 2 == 0 ? Int16(3000) : Int16(-3000) })
        let buffer = makeBuffer(samples: samples)
        // RMS of the whole buffer should be above silence threshold.
        #expect(!AudioLevelAnalyzer.isSilent(buffer))
    }
}
