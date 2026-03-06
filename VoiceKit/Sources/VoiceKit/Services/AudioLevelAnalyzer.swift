import Foundation

/// Analyze audio levels from WAV-encoded PCM data.
///
/// Compute RMS (root mean square) amplitude from an `AudioBuffer` to
/// detect silence or noise-only recordings before sending to the
/// dictation service.
public enum AudioLevelAnalyzer {

    /// Compute the RMS amplitude of a WAV-encoded audio buffer.
    ///
    /// Reads 16-bit signed PCM samples from the WAV data (skipping
    /// the 44-byte RIFF header) and returns the RMS level normalized
    /// to 0.0–1.0 where 1.0 represents full-scale 16-bit audio.
    ///
    /// - Parameter buffer: A WAV-encoded `AudioBuffer`.
    /// - Returns: Normalized RMS level (0.0–1.0), or 0.0 if the
    ///   buffer is empty or contains no PCM samples.
    public static func rmsLevel(of buffer: AudioBuffer) -> Float {
        let headerSize = 44
        let bytesPerSample = buffer.bitsPerSample / 8

        guard bytesPerSample > 0,
            buffer.data.count > headerSize
        else {
            return 0.0
        }

        let pcmData = buffer.data.dropFirst(headerSize)
        let sampleCount = pcmData.count / bytesPerSample

        guard sampleCount > 0 else { return 0.0 }

        var sumOfSquares: Double = 0.0

        pcmData.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let normalized = Double(samples[i]) / Double(Int16.max)
                sumOfSquares += normalized * normalized
            }
        }

        let rms = Float(sqrt(sumOfSquares / Double(sampleCount)))
        return min(rms, 1.0)
    }

    /// Check whether an audio buffer is below the silence threshold.
    ///
    /// - Parameters:
    ///   - buffer: A WAV-encoded `AudioBuffer`.
    ///   - threshold: RMS level below which audio is considered silent.
    ///     On 16-bit PCM normalized to 0–1, ambient silence produces
    ///     RMS around 0.0005–0.001 with a built-in mic. AirPods with
    ///     noise cancellation or nearby fans raise the floor to ~0.002.
    ///     Quiet speech starts around 0.01 and normal speech is 0.03+.
    ///     A threshold of 0.005 rejects ambient noise while allowing
    ///     even quiet speech through.
    /// - Returns: `true` if the audio is at or below the threshold.
    public static func isSilent(_ buffer: AudioBuffer, threshold: Float = 0.005) -> Bool {
        rmsLevel(of: buffer) <= threshold
    }
}
