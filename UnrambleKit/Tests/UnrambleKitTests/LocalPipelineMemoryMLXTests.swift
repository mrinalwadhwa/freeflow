import Darwin
import Foundation
import MLX
import Testing

@testable import UnrambleKit

#if UNRAMBLE_MLX_TESTS

@Suite("Local pipeline memory")
struct LocalPipelineMemoryMLXTests {
    @Test("Measure Cohere and optional Qwen memory in isolation")
    func measure() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-local-memory")
        else { return }

        let mode = try flag("/tmp/unramble-memory-mode") ?? "cohere-only"
        guard ["cohere-only", "current-qwen", "list-qwen"].contains(mode)
        else {
            Issue.record("unsupported memory mode \(mode)")
            return
        }
        guard let wavPath = try flag("/tmp/unramble-memory-wav") else {
            Issue.record("set /tmp/unramble-memory-wav to a 16 kHz mono WAV")
            return
        }
        guard let modelsDir = findUpwards("UnrambleApp/Resources/models") else {
            Issue.record("model pack not found")
            return
        }

        let fixture = try WAVFixture(
            data: Data(contentsOf: URL(fileURLWithPath: wavPath)))
        guard fixture.sampleRate == 16_000, fixture.channels == 1,
            fixture.bitsPerSample == 16
        else {
            Issue.record("memory fixture must be 16 kHz mono 16-bit PCM")
            return
        }

        Memory.clearCache()
        Memory.peakMemory = 0
        var samples: [[String: Any]] = []
        record("initial", into: &samples)

        let manager = LocalModelManager(modelsDirectory: modelsDir)
        let cohere = CohereMLXEngine(
            modelDirectory: manager.modelPath(
                for: "cohere-transcribe-03-2026-mlx-4bit"))
        try await cohere.load()
        record("cohere-loaded", into: &samples)

        _ = try LocalRecognitionFixtureSupport.recognize(
            wavData: fixture.canonicalWAV, using: cohere)
        record("cohere-inferred", into: &samples)

        var qwen: MLXLLMEngine?
        if mode != "cohere-only" {
            let adapterName = mode == "list-qwen"
                ? "qwen3-0.6b-4bit-list-adapter"
                : "qwen3-0.6b-4bit-polish-adapter"
            let engine = MLXLLMEngine(
                name: mode,
                modelDirectory: manager.modelPath(for: "qwen3-0.6b-4bit"),
                adapterDirectory: manager.modelPath(for: adapterName))
            qwen = engine
            try await engine.load()
            record("qwen-loaded", into: &samples)

            _ = try await engine.complete(
                systemPrompt: PolishPipeline.systemPromptQwen,
                userPrompt:
                    "Please order five monitors, three keyboards, and ten mice.",
                maxTokens: 128)
            record("qwen-inferred", into: &samples)
        }

        if let qwen {
            await qwen.unload()
            Memory.clearCache()
            record("qwen-unloaded", into: &samples)
        }

        let output = "/tmp/unramble-local-memory-\(mode).json"
        let payload: [String: Any] = [
            "mode": mode,
            "wav": wavPath,
            "samples": samples,
        ]
        try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)

        await cohere.unload()
        Memory.clearCache()
    }

    private func record(
        _ stage: String,
        into samples: inout [[String: Any]]
    ) {
        let memory = Memory.snapshot()
        samples.append([
            "stage": stage,
            "mlxActiveBytes": memory.activeMemory,
            "mlxCacheBytes": memory.cacheMemory,
            "mlxPeakBytes": memory.peakMemory,
            "processPeakResidentBytes": processPeakResidentBytes(),
        ])
    }

    private func processPeakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(usage.ru_maxrss)
    }

    private func flag(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let value = try String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func findUpwards(_ relative: String) -> URL? {
        var directory = URL(fileURLWithPath: #file)
        for _ in 0..<10 {
            directory = directory.deletingLastPathComponent()
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

#endif
