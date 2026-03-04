import Foundation

/// Orchestrate the full dictation flow from hotkey press to text injection.
///
/// `DictationPipeline` implements `PipelineProviding` by coordinating an
/// `AudioProviding`, `AppContextProviding`, and `TextInjecting` service.
/// It drives the `RecordingCoordinator` state machine through each phase:
///
///   1. `activate()` — transition to `.recording`, start audio capture,
///      begin reading app context in parallel.
///   2. `complete()` — transition to `.processing`, stop audio capture,
///      await context, run processing (STT stub), inject text, return to `.idle`.
///   3. `cancel()` — abort any in-progress pipeline run and reset to `.idle`.
///
/// The pipeline holds captured context from the `activate()` call so it is
/// available immediately when `complete()` runs.
public actor DictationPipeline: PipelineProviding {

    private let audioProvider: AudioProviding
    private let contextProvider: AppContextProviding
    private let textInjector: TextInjecting
    private let coordinator: RecordingCoordinator

    /// Context captured concurrently during the recording phase.
    private var pendingContext: Task<AppContext, Never>?

    /// The in-flight pipeline task, used for cancellation.
    private var pipelineTask: Task<Void, Never>?

    public init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator
    ) {
        self.audioProvider = audioProvider
        self.contextProvider = contextProvider
        self.textInjector = textInjector
        self.coordinator = coordinator
    }

    // MARK: - PipelineProviding

    public var state: RecordingState {
        get async {
            await coordinator.state
        }
    }

    public func activate() async {
        let currentState = await coordinator.state
        guard currentState == .idle else {
            debugPrint("[Pipeline] activate() ignored — state is \(currentState)")
            return
        }

        let started = await coordinator.startRecording()
        guard started else { return }

        // Start reading context concurrently. The result is awaited in complete().
        let ctxProvider = contextProvider
        pendingContext = Task {
            await ctxProvider.readContext()
        }

        // Start audio capture.
        do {
            try await audioProvider.startRecording()
        } catch {
            debugPrint("[Pipeline] Failed to start recording: \(error)")
            pendingContext?.cancel()
            pendingContext = nil
            await coordinator.reset()
        }
    }

    public func complete() async {
        let currentState = await coordinator.state
        guard currentState == .recording else {
            debugPrint("[Pipeline] complete() ignored — state is \(currentState)")
            return
        }

        let stopped = await coordinator.stopRecording()
        guard stopped else { return }

        let task = Task { [pendingContext, audioProvider, textInjector, coordinator] in
            // Stop audio capture and retrieve the buffer.
            let audioBuffer: AudioBuffer
            do {
                audioBuffer = try await audioProvider.stopRecording()
            } catch {
                debugPrint("[Pipeline] Failed to stop recording: \(error)")
                await coordinator.reset()
                return
            }

            // Await context (with a timeout so we don't block forever).
            let context: AppContext
            if let pendingContext {
                let result = await withTimeout(seconds: 0.5) {
                    await pendingContext.value
                }
                context = result ?? .empty
            } else {
                context = .empty
            }

            guard !Task.isCancelled else {
                await coordinator.reset()
                return
            }

            // Process audio (STT stub — returns placeholder text).
            let transcribedText = processAudio(audioBuffer, context: context)

            guard !Task.isCancelled else {
                await coordinator.reset()
                return
            }

            // Transition to injecting.
            let injecting = await coordinator.startInjecting()
            guard injecting else {
                await coordinator.reset()
                return
            }

            // Inject the transcribed text.
            do {
                try await textInjector.inject(text: transcribedText, into: context)
            } catch {
                debugPrint("[Pipeline] Text injection failed: \(error)")
            }

            // Return to idle.
            await coordinator.finishInjecting()
        }

        self.pipelineTask = task
        self.pendingContext = nil

        await task.value
        self.pipelineTask = nil
    }

    public func cancel() async {
        pipelineTask?.cancel()
        pipelineTask = nil
        pendingContext?.cancel()
        pendingContext = nil

        // Stop audio if currently recording.
        if audioProvider.isRecording {
            _ = try? await audioProvider.stopRecording()
        }

        await coordinator.reset()
    }
}

// MARK: - Audio processing stub

/// Process captured audio into text.
///
/// This is a placeholder that returns a fixed string. A real implementation
/// will send the audio buffer to a speech-to-text service and optionally
/// run the result through an LLM for context-aware refinement.
private func processAudio(_ buffer: AudioBuffer, context: AppContext) -> String {
    let durationStr = String(format: "%.1f", buffer.duration)
    let app = context.appName.isEmpty ? "unknown app" : context.appName
    return "[Transcribed \(durationStr)s of audio from \(app)]"
}
