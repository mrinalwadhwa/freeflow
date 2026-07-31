import Foundation
import Testing

@testable import UnrambleKit

#if UNRAMBLE_MLX_TESTS

@Suite("Local list formatting MLX")
struct LocalListFormattingMLXTests {
    @Test("Evaluate every saved list scenario through the release gate")
    func evaluateSavedListScenarios() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-list-formatting-mlx")
        else { return }
        guard let modelsDir = findUpwards("UnrambleApp/Resources/models")
        else {
            Issue.record("model pack not found")
            return
        }

        let manager = LocalModelManager(modelsDirectory: modelsDir)
        let engine = MLXLLMEngine(
            name: "Qwen3 0.6B List Formatter",
            modelDirectory: manager.modelPath(for: "qwen3-0.6b-4bit"),
            adapterDirectory: manager.modelPath(
                for: "qwen3-0.6b-4bit-list-adapter"))
        let client = MLXPolishClient(engine: engine, timeoutSeconds: 30)
        let scenarios = allScenarios.filter { $0.category == "list" }
        var records: [[String: Any]] = []

        for (index, scenario) in scenarios.enumerated() {
            let output = await LocalListFormattingPipeline.formatIfSafe(
                scenario.input,
                chatClient: client,
                model: "local",
                tone: scenario.style,
                precedingText: scenario.precedingText)
            records.append([
                "index": index,
                "input": scenario.input,
                "candidate": LocalListFormattingPipeline.isCandidate(
                    scenario.input),
                "accepted": output != nil,
                "matchesScenario": output.map(scenario.matches) ?? false,
                "output": output ?? scenario.input,
            ])
        }

        let nonListCandidates = allScenarios.filter {
            $0.category != "list"
                && LocalListFormattingPipeline.isCandidate($0.input)
        }.map {
            ["category": $0.category, "input": $0.input]
        }
        let payload: [String: Any] = [
            "listScenarioCount": scenarios.count,
            "acceptedCount": records.count(where: {
                $0["accepted"] as? Bool == true
            }),
            "matchingCount": records.count(where: {
                $0["matchesScenario"] as? Bool == true
            }),
            "nonListCandidateCount": nonListCandidates.count,
            "nonListCandidates": nonListCandidates,
            "records": records,
        ]
        try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            .write(
                to: URL(fileURLWithPath:
                    "/tmp/unramble-list-formatting-mlx.json"),
                options: .atomic)
        await engine.unload()
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
