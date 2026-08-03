import Foundation
import MLXAudioTTS
import MLXLMCommon
import Testing

#if canImport(HuggingFace)
    import HuggingFace
#endif

@testable import UnrambleKit

#if UNRAMBLE_MLX_TESTS

@Suite("Kokoro synthesis")
struct KokoroSynthesisMLXTests {

    @Test("The packed model synthesizes audio offline")
    func packedModelSynthesizes() async throws {
        guard let modelsDir = findUpwards("UnrambleApp/Resources/models")
        else {
            Issue.record("model pack not found")
            return
        }
        let kokoro = modelsDir.appendingPathComponent("kokoro-82m-bf16")
        let g2p = modelsDir.appendingPathComponent("kokoro-g2p-en")
        guard
            FileManager.default.fileExists(
                atPath: kokoro.appendingPathComponent(
                    "kokoro-v1_0.safetensors").path)
        else {
            Issue.record("kokoro weights missing from the model pack")
            return
        }

        // The same load path the app's synthesizer uses: seed the hub
        // cache from the pack, prepare the English G2P, load the model
        // from the pack directory, and synthesize one sentence.
        try KokoroG2PResourceInstaller.install(
            from: g2p,
            intoHubCacheDirectory: HubCache.default.cacheDirectory)
        let processor = MisakiTextProcessor()
        try await processor.prepare()
        let model = try await KokoroModel.fromModelDirectory(
            kokoro, textProcessor: processor)

        let audio = try await model.generate(
            text: "The read aloud voice is working.",
            voice: "af_heart",
            refAudio: nil,
            refText: nil,
            language: nil,
            generationParameters: GenerateParameters())
        let samples = audio.asArray(Float.self)

        let seconds = Double(samples.count) / 24_000.0
        #expect(seconds > 0.5, "expected speech, got \(seconds)s")
        #expect(samples.contains { abs($0) > 0.01 }, "audio is silent")
    }

    private func findUpwards(_ relative: String) -> URL? {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

#endif
