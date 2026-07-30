import Foundation
import MLX
import MLXAudioSTT

/// Cohere Transcribe backed by MLX and a bounded rolling audio window.
public final class CohereMLXEngine: LocalStreamingRecognizer,
    @unchecked Sendable
{
    public let name = "Cohere Transcribe 03-2026 MLX"

    private let modelDirectory: URL
    private let stateLock = NSLock()
    private let inferenceLock = NSLock()
    private var model: CohereTranscribeModel?

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public var isReady: Bool {
        stateLock.withLock { model != nil }
    }

    public func load() async throws {
        if isReady { return }
        try Self.validateModelDirectory(modelDirectory)
        try Task.checkCancellation()
        let loaded = try CohereTranscribeModel.fromDirectory(modelDirectory)
        try Task.checkCancellation()
        stateLock.withLock {
            if model == nil { model = loaded }
        }
        Log.debug("[CohereMLXEngine] Model loaded")
    }

    public func unload() async {
        clearLoadedModel()
        Memory.clearCache()
        Log.debug("[CohereMLXEngine] Model unloaded")
    }

    public func makeRecognitionSession()
        throws -> any LocalRecognitionSession
    {
        guard isReady else { throw LocalModelError.modelNotLoaded }
        return CohereRollingRecognitionSession { [self] samples in
            try transcribe(samples)
        }
    }

    fileprivate func transcribe(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        guard let model = stateLock.withLock({ model }) else {
            throw LocalModelError.modelNotLoaded
        }
        let parameters = STTGenerateParameters(
            maxTokens: 2_048,
            temperature: 0,
            topP: 1,
            topK: 0,
            verbose: false,
            language: "en")
        return model.generate(
            audio: MLXArray(samples),
            generationParameters: parameters
        ).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clearLoadedModel() {
        inferenceLock.withLock {
            stateLock.withLock { model = nil }
        }
    }

    private static func validateModelDirectory(_ directory: URL) throws {
        guard directory.isFileURL else {
            throw LocalModelError.modelLoadFailed(
                "Cohere model directory must be a local file URL")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw LocalModelError.modelNotFound(directory.path)
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path)) ?? []
        let required = ["config.json", "tokenizer.model"]
        let missing = required.filter { !files.contains($0) }
        let hasWeights = files.contains { $0.hasSuffix(".safetensors") }
        guard missing.isEmpty, hasWeights else {
            let details = missing + (hasWeights ? [] : ["*.safetensors"])
            throw LocalModelError.modelLoadFailed(
                "Incomplete Cohere MLX model at \(directory.path); missing "
                    + details.joined(separator: ", "))
        }
    }
}

final class CohereRollingRecognitionSession: LocalRecognitionSession {
    private static let sampleRate = 16_000
    private static let windowSamples = 30 * sampleRate
    private static let strideSamples = 25 * sampleRate
    private static let overlapSamples = windowSamples - strideSamples
    private static let minimumStandaloneTailSamples = 8 * sampleRate

    private let transcribeWindow: ([Float]) throws -> String
    private var samples: [Float] = []
    private var assembled = ""
    private var published = ""
    private var assembledBeforeLastWindow = ""
    private var lastWindow: [Float] = []
    private var processedWindow = false
    private var finished = false

    init(transcribeWindow: @escaping ([Float]) throws -> String) {
        self.transcribeWindow = transcribeWindow
    }

    var preservesContextAcrossHardPauses: Bool { true }

    func feed(_ newSamples: [Float]) throws {
        guard !finished else {
            throw LocalModelError.modelLoadFailed(
                "Cannot feed a finished Cohere recognition session")
        }
        samples.append(contentsOf: newSamples)
        while samples.count >= Self.windowSamples {
            let window = Array(samples.prefix(Self.windowSamples))
            assembledBeforeLastWindow = assembled
            lastWindow = window
            try merge(transcribeWindow(window))
            processedWindow = true
            samples.removeFirst(Self.strideSamples)
            publishConfirmedPrefix()
        }
    }

    func transcript() -> String { published }

    func finish() throws -> String {
        if finished { return assembled }
        finished = true
        let newTailCount = processedWindow
            ? max(0, samples.count - Self.overlapSamples)
            : samples.count
        if processedWindow,
            newTailCount > 0,
            newTailCount < Self.minimumStandaloneTailSamples
        {
            // Re-run the most recent 30-second window with this tiny tail
            // attached. A standalone 5–12 second overlap+tail is both lower
            // context and more prone to hallucination. The published prefix
            // comes only from the checkpoint before this window, so replacing
            // it cannot revise text already consumed by the provider.
            let newTail = Array(samples.suffix(newTailCount))
            assembled = assembledBeforeLastWindow
            try merge(transcribeWindow(lastWindow + newTail))
        } else if newTailCount > 0 {
            try merge(transcribeWindow(samples))
        }
        published = assembled
        samples.removeAll(keepingCapacity: false)
        return assembled
    }

    private func merge(_ text: String) throws {
        #if DEBUG
        if FileManager.default.fileExists(atPath: "/tmp/unramble-unit-trace"),
            let data = try? JSONSerialization.data(withJSONObject: [
                "assembled_before": assembled,
                "window": text,
                "published": published,
            ]),
            let line = String(data: data, encoding: .utf8)
        {
            Log.debug("[[COHERE_WINDOW]] \(line)")
        }
        #endif
        let result = CohereTranscriptAssembler.merge(assembled, text)
        guard result.text.hasPrefix(published) else {
            throw LocalModelError.modelLoadFailed(
                "Cohere overlap revised an already-published transcript prefix")
        }
        assembled = result.text
        Log.debug(
            "[CohereMLXEngine] Window merged method=\(result.method.rawValue)"
                + " overlap=\(result.leftOverlapWords)/"
                + "\(result.rightOverlapWords)"
                + " punctuationRepair="
                + "\(result.repairedContinuationPunctuation)")
    }

    private func publishConfirmedPrefix() {
        // Do not publish words from the newest audio window. Finish may need
        // to replace that window with a slightly extended version when the
        // user stops just after a stride boundary.
        let candidate = CohereTranscriptAssembler.stablePrefix(
            of: assembledBeforeLastWindow)
        if candidate.hasPrefix(published) {
            published = candidate
        }
    }
}
