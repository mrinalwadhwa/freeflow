import Foundation

/// The mode-specific pieces of a dictation composition: the backend, an
/// optional session-expiry handler (cloud only), and the local model runtime
/// (local only). The app builds the `DictationPipeline` from these plus its own
/// singletons.
public struct DictationComposition {
    public let backend: DictationBackend
    public let onSessionExpired: (@Sendable () -> Void)?
    public let localRuntime: LocalModelRuntime?
}

/// Build the backend for a dictation mode. Cloud construction is inert (it opens
/// no connection until the backend is used); local construction resolves the
/// on-device model directories and wires the MLX engines.
public enum DictationCompositionFactory {
    enum LocalSTTKind: Equatable {
        case nemotron
        case cohereMLX
    }

    /// Cloud composition: OpenAI streaming transcription with a batch fallback.
    public static func makeCloud(
        apiKey: String,
        onSessionExpired: (@Sendable () -> Void)?
    ) -> DictationComposition {
        DictationComposition(
            backend: .cloud(
                realtime: OpenAIStreamingProvider(apiKey: apiKey),
                fallback: OpenAIFileTranscriber(apiKey: apiKey)),
            onSessionExpired: onSessionExpired,
            localRuntime: nil)
    }

    #if arch(arm64)
    /// Local composition: on-device STT with fine-tuned MLX LLM polish.
    /// Terminates with `fatalError` when a required model directory is missing,
    /// so a corrupt or incomplete install fails loudly at launch.
    public static func makeLocal(
        modelManager: LocalModelManager,
        bundledModelsRoot: URL?,
        cycleInterval: TimeInterval,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DictationComposition {
        guard let qwenModelPath = modelManager.resolveModelDirectory(
            modelID: "qwen3-0.6b-4bit", file: "model.safetensors",
            bundledModelsRoot: bundledModelsRoot)
        else {
            fatalError("Required local model is missing: qwen3-0.6b-4bit")
        }
        guard let adapterPath = modelManager.resolveModelDirectory(
            modelID: "qwen3-0.6b-4bit-polish-adapter", file: "adapters.safetensors",
            bundledModelsRoot: bundledModelsRoot)
        else {
            fatalError(
                "Required local model is missing: "
                    + "qwen3-0.6b-4bit-polish-adapter")
        }
        let sttKind = localSTTKind(environment: environment)
        let sttEngine: any LocalStreamingRecognizer
        switch sttKind {
        case .nemotron:
            guard let nemotronPath = modelManager.resolveModelDirectory(
                modelID: "nemotron-speech-streaming-en-0.6b-coreml",
                file: "nemotron_coreml_560ms/tokenizer.json",
                bundledModelsRoot: bundledModelsRoot
            ) else {
                fatalError(
                    "Required local model is missing: "
                        + "nemotron-speech-streaming-en-0.6b-coreml")
            }
            sttEngine = NemotronEngine(
                modelManager: modelManager, modelPath: nemotronPath)
        case .cohereMLX:
            guard let coherePath = modelManager.resolveModelDirectory(
                modelID: "cohere-transcribe-03-2026-mlx-4bit",
                file: "model.safetensors",
                bundledModelsRoot: bundledModelsRoot
            ) else {
                fatalError(
                    "Required local model is missing: "
                        + "cohere-transcribe-03-2026-mlx-4bit")
            }
            sttEngine = CohereMLXEngine(
                modelDirectory: URL(
                    fileURLWithPath: coherePath, isDirectory: true))
        }
        let llmEngine = MLXLLMEngine(
            name: "Qwen3 0.6B Polish",
            modelDirectory: URL(
                fileURLWithPath: qwenModelPath, isDirectory: true),
            adapterDirectory: URL(
                fileURLWithPath: adapterPath, isDirectory: true))
        let polisher: any PolishChatClient = MLXPolishClient(engine: llmEngine)
        let runtime = LocalModelRuntime(
            sttEngine: sttEngine, llmEngine: llmEngine)
        let backend: DictationBackend = .local(
            streaming: LocalStreamingProvider(
                sttEngine: sttEngine, polishChatClient: polisher,
                cycleInterval: cycleInterval,
                unitPolicy: localUnitPolicy(for: sttKind),
                polishBatchTokenLimit:
                    sttKind == .cohereMLX ? 256 : nil,
                loadSTT: { try await runtime.loadSTT() }))
        return DictationComposition(
            backend: backend,
            onSessionExpired: nil,
            localRuntime: runtime)
    }
    #endif

    static func localSTTKind(
        environment: [String: String]
    ) -> LocalSTTKind {
        let value = environment["UNRAMBLE_LOCAL_STT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "cohere-mlx" ? .cohereMLX : .nemotron
    }

    static func localUnitPolicy(for sttKind: LocalSTTKind) -> LocalUnitPolicy {
        switch sttKind {
        case .nemotron:
            return LocalUnitPolicy()
        case .cohereMLX:
            // Cohere already returns coherent, punctuated text. Close work
            // often enough to hide Qwen latency while the user keeps speaking;
            // sentence-aware batching keeps this audio boundary out of Qwen.
            return LocalUnitPolicy(maximumUnitSeconds: 90)
        }
    }

    /// Resolve the streaming cycle interval, honoring a positive
    /// `UNRAMBLE_CYCLE_INTERVAL` override and defaulting to three seconds.
    public static func cycleInterval(
        from environment: [String: String]
    ) -> TimeInterval {
        if let raw = environment["UNRAMBLE_CYCLE_INTERVAL"],
            let value = Double(raw), value > 0 {
            return value
        }
        return 3
    }
}
