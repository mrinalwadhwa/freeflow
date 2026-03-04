import Foundation

/// Orchestrate the full dictation flow from hotkey press to text injection.
///
/// `DictationPipeline` implements `PipelineProviding` by coordinating an
/// `AudioProviding`, `AppContextProviding`, `STTProviding`, and
/// `TextInjecting` service. It drives the `RecordingCoordinator` state
/// machine through each phase:
///
///   1. `activate()` — transition to `.recording`, start audio capture,
///      begin reading app context in parallel.
///   2. `complete()` — transition to `.processing`, stop audio capture,
///      await context, transcribe audio via STT, inject text, return to `.idle`.
///   3. `cancel()` — abort any in-progress pipeline run and reset to `.idle`.
///
/// The pipeline holds captured context from the `activate()` call so it is
/// available immediately when `complete()` runs.
///
/// After successful STT, the transcript is stored in a `TranscriptBuffer`
/// before injection. If injection fails (no focused text field), the pipeline
/// transitions to `.injectionFailed` so the HUD can show no-target recovery.
/// The transcript remains in the buffer for re-paste via the special shortcut.
public actor DictationPipeline: PipelineProviding {

    private let audioProvider: AudioProviding
    private let contextProvider: AppContextProviding
    private let sttProvider: STTProviding
    private let textInjector: TextInjecting
    private let coordinator: RecordingCoordinator
    private let transcriptBuffer: TranscriptBuffer?

    /// Minimum audio duration (in seconds) worth transcribing.
    private let minimumAudioDuration: TimeInterval = 0.1

    /// Context captured concurrently during the recording phase.
    private var pendingContext: Task<AppContext, Never>?

    /// The in-flight pipeline task, used for cancellation.
    private var pipelineTask: Task<Void, Never>?

    public init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        sttProvider: STTProviding,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil
    ) {
        self.audioProvider = audioProvider
        self.contextProvider = contextProvider
        self.sttProvider = sttProvider
        self.textInjector = textInjector
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
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

        let task = Task {
            [
                pendingContext, audioProvider, sttProvider, textInjector, coordinator,
                minimumAudioDuration, transcriptBuffer
            ] in
            // Stop audio capture and retrieve the buffer.
            let audioBuffer: AudioBuffer
            do {
                audioBuffer = try await audioProvider.stopRecording()
            } catch {
                debugPrint("[Pipeline] Failed to stop recording: \(error)")
                await coordinator.reset()
                return
            }

            // Skip transcription for empty or very short audio.
            guard !audioBuffer.data.isEmpty, audioBuffer.duration >= minimumAudioDuration else {
                debugPrint("[Pipeline] Audio too short (\(audioBuffer.duration)s), skipping STT")
                await coordinator.reset()
                return
            }

            // Await context (with a timeout so we do not block forever).
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

            // Transcribe audio via STT service.
            let transcribedText: String
            do {
                transcribedText = try await sttProvider.transcribe(audio: audioBuffer.data)
            } catch {
                debugPrint("[Pipeline] STT failed: \(error)")
                await coordinator.reset()
                return
            }

            // Skip injection for empty or whitespace-only transcriptions.
            let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                debugPrint("[Pipeline] Empty transcription, skipping injection")
                await coordinator.reset()
                return
            }

            guard !Task.isCancelled else {
                await coordinator.reset()
                return
            }

            // Store the transcript before injection so it survives injection
            // failure and is available for no-target recovery or re-paste.
            await transcriptBuffer?.store(trimmed)

            // Transition to injecting.
            let injecting = await coordinator.startInjecting()
            guard injecting else {
                await coordinator.reset()
                return
            }

            // Inject the transcribed text.
            do {
                try await textInjector.inject(text: trimmed, into: context)
            } catch {
                debugPrint("[Pipeline] Text injection failed: \(error)")
                // Signal injection failure so the HUD shows no-target recovery.
                // The transcript stays in the buffer for re-paste.
                await coordinator.failInjection()
                return
            }

            // Successful injection — return to idle.
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
