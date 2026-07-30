import Foundation
import Testing

@testable import UnrambleKit

@Suite("Dictation composition factory")
struct DictationCompositionFactoryTests {

    @Test("Cloud composition builds a cloud backend and forwards the handler")
    func cloudComposition() {
        let composition = DictationCompositionFactory.makeCloud(
            apiKey: "sk-test", onSessionExpired: {})

        guard case .cloud = composition.backend else {
            Issue.record("expected a cloud backend")
            return
        }
        #expect(composition.localRuntime == nil)
        #expect(composition.onSessionExpired != nil)
    }

    @Test("Cloud composition allows a nil expiry handler")
    func cloudCompositionNilHandler() {
        let composition = DictationCompositionFactory.makeCloud(
            apiKey: "sk-test", onSessionExpired: nil)

        guard case .cloud = composition.backend else {
            Issue.record("expected a cloud backend")
            return
        }
        #expect(composition.onSessionExpired == nil)
    }

    #if arch(arm64)
    @Test("Local composition uses the bundled Cohere model")
    func localCompositionUsesCohere() throws {
        let modelsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: modelsRoot) }

        for (directory, file) in [
            ("qwen3-0.6b-4bit", "model.safetensors"),
            (
                "qwen3-0.6b-4bit-polish-adapter",
                "adapters.safetensors"
            ),
            (
                "cohere-transcribe-03-2026-mlx-4bit",
                "model.safetensors"
            ),
        ] {
            let modelDirectory = modelsRoot.appendingPathComponent(
                directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: modelDirectory, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(
                atPath: modelDirectory.appendingPathComponent(file).path,
                contents: Data())
        }

        let composition = DictationCompositionFactory.makeLocal(
            modelManager: LocalModelManager(
                modelsDirectory: modelsRoot.appendingPathComponent("unused")),
            bundledModelsRoot: modelsRoot,
            cycleInterval: 3)

        guard case .local = composition.backend else {
            Issue.record("expected a local backend")
            return
        }
        #expect(
            composition.localRuntime?.sttEngine.name
                == "Cohere Transcribe 03-2026 MLX")
    }
    #endif

    @Test("Cohere gives Qwen complete thoughts with a bounded fallback")
    func cohereUnitPolicy() {
        let policy = DictationCompositionFactory.localUnitPolicy

        #expect(
            policy.maximumUnitBytes
                == 90 * LocalUnitPolicy.sourceBytesPerSecond)
    }

    @Test("Cycle interval defaults to three seconds without an override")
    func cycleIntervalDefault() {
        #expect(DictationCompositionFactory.cycleInterval(from: [:]) == 3)
    }

    @Test("Cycle interval honors a positive override")
    func cycleIntervalOverride() {
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "1.5"]) == 1.5)
    }

    @Test("Cycle interval ignores a non-positive or invalid override")
    func cycleIntervalRejectsInvalid() {
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "0"]) == 3)
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "-2"]) == 3)
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "not-a-number"]) == 3)
    }
}
