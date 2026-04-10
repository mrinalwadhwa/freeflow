import AVFoundation

/// Convert raw PCM data to `AVAudioPCMBuffer` for Apple Speech APIs.
public enum PCMBufferConverter {

    /// Convert 16-bit mono PCM data to an `AVAudioPCMBuffer`.
    ///
    /// - Parameters:
    ///   - pcm16: Raw 16-bit little-endian signed integer PCM samples.
    ///   - sampleRate: Sample rate in Hz (e.g. 16000).
    /// - Returns: A buffer containing the same audio as 32-bit float PCM,
    ///   or nil if the input is empty or the format cannot be created.
    public static func convert(
        pcm16: Data, sampleRate: Int
    ) -> AVAudioPCMBuffer? {
        let byteCount = pcm16.count
        guard byteCount >= 2 else { return nil }

        let sampleCount = byteCount / 2
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else { return nil }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let floatData = buffer.floatChannelData?[0] else { return nil }

        // Copy into a contiguous array first to avoid Data's
        // potentially discontiguous internal storage.
        let bytes = [UInt8](pcm16)
        for i in 0..<sampleCount {
            let lo = UInt16(bytes[i &* 2])
            let hi = UInt16(bytes[i &* 2 &+ 1])
            let raw = Int16(bitPattern: lo | (hi &<< 8))
            floatData[i] = Float(raw) / 32768.0
        }

        return buffer
    }
}
