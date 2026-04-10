import AVFoundation
import Testing

@testable import FreeFlowKit

@Suite("PCMBufferConverter")
struct PCMBufferConverterTests {

    @Test("converts 16-bit PCM to float buffer with correct frame count")
    func convertsToFloat() {
        // 4 samples of 16-bit PCM = 8 bytes.
        var data = Data()
        for sample: Int16 in [0, 16384, -16384, 32767] {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }

        let buffer = PCMBufferConverter.convert(pcm16: data, sampleRate: 16000)
        let buf = try! #require(buffer)
        #expect(buf.frameLength == 4)
        #expect(buf.format.sampleRate == 16000)
        #expect(buf.format.channelCount == 1)

        let floats = buf.floatChannelData![0]
        #expect(floats[0] == 0.0)
        #expect(abs(floats[1] - 0.5) < 0.001)
        #expect(abs(floats[2] - (-0.5)) < 0.001)
        #expect(abs(floats[3] - (32767.0 / 32768.0)) < 0.001)
    }

    @Test("returns nil for empty data")
    func emptyData() {
        #expect(PCMBufferConverter.convert(pcm16: Data(), sampleRate: 16000) == nil)
    }

    @Test("returns nil for single byte (incomplete sample)")
    func incompleteSample() {
        #expect(PCMBufferConverter.convert(pcm16: Data([0x42]), sampleRate: 16000) == nil)
    }

    @Test("preserves sample rate")
    func sampleRate() {
        var data = Data()
        withUnsafeBytes(of: Int16(100).littleEndian) { data.append(contentsOf: $0) }

        let buf16k = PCMBufferConverter.convert(pcm16: data, sampleRate: 16000)
        #expect(buf16k?.format.sampleRate == 16000)

        let buf44k = PCMBufferConverter.convert(pcm16: data, sampleRate: 44100)
        #expect(buf44k?.format.sampleRate == 44100)
    }
}
