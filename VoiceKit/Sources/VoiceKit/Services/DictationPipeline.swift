import Foundation

/// Orchestrate the full dictation flow from hotkey press to text injection.
///
/// `DictationPipeline` implements `PipelineProviding` by coordinating an
/// `AudioProviding`, `AppContextProviding`, `DictationProviding`, and
/// `TextInjecting` service. It drives the `RecordingCoordinator` state
/// machine through each phase:
///
///   1. `activate()` — transition to `.recording`, start audio capture,
///      begin reading app context in parallel. If a streaming provider
///      is configured, open the streaming session and start forwarding
///      PCM chunks in the background.
///   2. `complete()` — transition to `.processing`, stop audio capture,
///      await context, send audio + context to the dictation service,
///      inject text, return to `.idle`. In streaming mode, call
///      `finishStreaming()` instead of the batch dictation endpoint.
///   3. `cancel()` — abort any in-progress pipeline run and reset to `.idle`.
///
/// The pipeline holds captured context from the `activate()` call so it is
/// available immediately when `complete()` runs.
///
/// After successful dictation, the final text is stored in a `TranscriptBuffer`
/// before injection. If injection fails (no focused text field), the pipeline
/// transitions to `.injectionFailed` so the HUD can show no-target recovery.
/// The transcript remains in the buffer for re-paste via the special shortcut.
public actor DictationPipeline: PipelineProviding {

    private let audioProvider: AudioProviding
    private let contextProvider: AppContextProviding
    private let dictationProvider: DictationProviding
    private let streamingProvider: StreamingDictationProviding?
    private let textInjector: TextInjecting
    private let coordinator: RecordingCoordinator
    private let transcriptBuffer: TranscriptBuffer?

    /// Minimum audio duration (in seconds) worth sending to the server.
    private let minimumAudioDuration: TimeInterval = 0.1

    /// RMS level at or below which audio is considered silent.
    /// On 16-bit PCM normalized to 0–1, ambient silence produces
    /// RMS around 0.0005–0.001 and quiet speech around 0.002–0.01.
    /// A threshold of 0.001 rejects near-silence while allowing
    /// even quiet speech through.
    private let silenceThreshold: Float

    /// Context captured concurrently during the recording phase.
    private var pendingContext: Task<AppContext, Never>?

    /// The in-flight pipeline task, used for cancellation.
    private var pipelineTask: Task<Void, Never>?

    /// Background task that forwards PCM chunks to the streaming provider.
    private var audioForwardingTask: Task<Void, Never>?

    /// Whether the current recording session is using streaming mode.
    private var isStreamingSession: Bool = false

    public init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        dictationProvider: DictationProviding,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        silenceThreshold: Float = 0.001,
        streamingProvider: StreamingDictationProviding? = nil
    ) {
        self.audioProvider = audioProvider
        self.contextProvider = contextProvider
        self.dictationProvider = dictationProvider
        self.textInjector = textInjector
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
        self.silenceThreshold = silenceThreshold
        self.streamingProvider = streamingProvider
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
            return
        }

        // If a streaming provider is available and the audio provider
        // supports PCM streaming, open the streaming session and start
        // forwarding audio chunks in the background.
        if let streaming = streamingProvider, let pcmStream = audioProvider.pcmAudioStream {
            isStreamingSession = true

            // Await context early for the streaming start message. Use
            // a short timeout so we do not delay the session opening.
            let context: AppContext
            if let pending = pendingContext {
                let result = await withTimeout(seconds: 0.5) {
                    await pending.value
                }
                context = result ?? .empty
            } else {
                context = .empty
            }

            do {
                try await streaming.startStreaming(context: context, language: nil)
            } catch {
                debugPrint("[Pipeline] Failed to start streaming session: \(error)")
                // Fall back to batch mode.
                isStreamingSession = false
                return
            }

            // Start a background task that reads PCM chunks and sends them.
            audioForwardingTask = Task {
                for await chunk in pcmStream {
                    guard !Task.isCancelled else { break }
                    do {
                        try await streaming.sendAudio(chunk)
                    } catch {
                        debugPrint("[Pipeline] Error sending audio chunk: \(error)")
                        break
                    }
                }
            }
        } else {
            isStreamingSession = false
        }
    }

    public func complete() async {
        debugPrint("[Pipeline] complete() entering")
        let currentState = await coordinator.state
        guard currentState == .recording else {
            debugPrint("[Pipeline] complete() ignored — state is \(currentState)")
            return
        }

        debugPrint("[Pipeline] complete() transitioning to processing")
        let stopped = await coordinator.stopRecording()
        guard stopped else { return }

        let useStreaming = isStreamingSession
        let forwardingTask = audioForwardingTask
        audioForwardingTask = nil
        isStreamingSession = false

        let task = Task {
            [
                pendingContext, audioProvider, dictationProvider, streamingProvider,
                textInjector, coordinator, minimumAudioDuration, silenceThreshold,
                transcriptBuffer
            ] in
            let t0 = CFAbsoluteTimeGetCurrent()

            // Stop audio capture and retrieve the buffer.
            debugPrint("[Pipeline] stopping audio capture")
            let audioBuffer: AudioBuffer
            do {
                audioBuffer = try await audioProvider.stopRecording()
            } catch {
                debugPrint("[Pipeline] Failed to stop recording: \(error)")
                if useStreaming, let streaming = streamingProvider {
                    forwardingTask?.cancel()
                    await streaming.cancelStreaming()
                }
                await coordinator.reset()
                return
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            debugPrint(
                "[Pipeline] audio stopped (\(String(format: "%.2f", audioBuffer.duration))s, \(audioBuffer.data.count)B)"
            )

            // Wait for the audio forwarding task to finish (the stream
            // ends when stopRecording() is called, so this should be fast).
            forwardingTask?.cancel()
            await forwardingTask?.value

            // Resolve context once. The pendingContext task caches its
            // result, so awaiting it again (streaming already awaited it
            // in activate) returns the same value instantly.
            let context: AppContext
            if let pendingContext {
                let result = await withTimeout(seconds: 0.5) {
                    await pendingContext.value
                }
                context = result ?? .empty
            } else {
                context = .empty
            }

            let dictatedText: String

            if useStreaming, let streaming = streamingProvider {
                // Streaming mode: the server already has all the audio.
                // Skip the silence gate — the Realtime API handles silence
                // detection. Just call finishStreaming() to get the
                // cleaned-up text.
                debugPrint("[Pipeline] finishing streaming session")
                do {
                    dictatedText = try await streaming.finishStreaming()
                } catch {
                    debugPrint(
                        "[Pipeline] Streaming dictation failed: \(error), falling back to batch")

                    // Fall back to batch mode using the captured audio buffer.
                    let batchResult = await batchDictate(
                        audioBuffer: audioBuffer,
                        context: context,
                        dictationProvider: dictationProvider,
                        minimumAudioDuration: minimumAudioDuration,
                        silenceThreshold: silenceThreshold,
                        coordinator: coordinator
                    )
                    guard let text = batchResult else { return }
                    dictatedText = text
                }
            } else {
                // Batch mode: send the complete audio buffer to /dictate.
                debugPrint("[Pipeline] silence gate passed, awaiting context")
                debugPrint("[Pipeline] context resolved, sending to dictation service")

                let batchResult = await batchDictate(
                    audioBuffer: audioBuffer,
                    context: context,
                    dictationProvider: dictationProvider,
                    minimumAudioDuration: minimumAudioDuration,
                    silenceThreshold: silenceThreshold,
                    coordinator: coordinator
                )
                guard let text = batchResult else { return }
                dictatedText = text
            }

            let t4 = CFAbsoluteTimeGetCurrent()
            debugPrint("[Pipeline] dictation returned, injecting text")

            // Skip injection for empty or whitespace-only text.
            let finalText = dictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                debugPrint("[Pipeline] Empty dictation result, skipping injection")
                await coordinator.reset()
                return
            }

            guard !Task.isCancelled else {
                await coordinator.reset()
                return
            }

            // Store the transcript before injection so it survives injection
            // failure and is available for no-target recovery or re-paste.
            await transcriptBuffer?.store(finalText)

            // Transition to injecting.
            let injecting = await coordinator.startInjecting()
            guard injecting else {
                await coordinator.reset()
                return
            }

            // Inject the composed text.
            do {
                try await textInjector.inject(text: finalText, into: context)
            } catch {
                debugPrint("[Pipeline] Text injection failed: \(error)")
                // Signal injection failure so the HUD shows no-target recovery.
                // The transcript stays in the buffer for re-paste.
                await coordinator.failInjection()
                return
            }

            let t5 = CFAbsoluteTimeGetCurrent()

            // Log timing for each pipeline phase.
            let fmt = { (dt: Double) -> String in String(format: "%.2fs", dt) }
            let audioKB = String(format: "%.0f", Double(audioBuffer.data.count) / 1024.0)
            let mode = useStreaming ? "streaming" : "batch"
            debugPrint(
                "[Pipeline] Timing:"
                    + " stop=\(fmt(t1 - t0))"
                    + " dictate=\(fmt(t4 - t1))"
                    + " inject=\(fmt(t5 - t4))"
                    + " total=\(fmt(t5 - t0))"
                    + " audio=\(audioKB)KB/\(fmt(audioBuffer.duration))"
                    + " mode=\(mode)"
            )

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

        // Cancel audio forwarding if streaming.
        audioForwardingTask?.cancel()
        audioForwardingTask = nil

        // Cancel the streaming session if active.
        if isStreamingSession, let streaming = streamingProvider {
            isStreamingSession = false
            await streaming.cancelStreaming()
        }

        // Stop audio if currently recording.
        if audioProvider.isRecording {
            _ = try? await audioProvider.stopRecording()
        }

        await coordinator.reset()
    }

    // MARK: - Batch Dictation Helper

    /// Run the batch dictation path: silence gate, then POST to /dictate.
    ///
    /// Return the dictated text on success, or nil if the pipeline should
    /// abort (audio too short, silent, cancelled, or dictation failed).
    /// On nil return, the coordinator has already been reset.
    private func batchDictate(
        audioBuffer: AudioBuffer,
        context: AppContext,
        dictationProvider: DictationProviding,
        minimumAudioDuration: TimeInterval,
        silenceThreshold: Float,
        coordinator: RecordingCoordinator
    ) async -> String? {
        // Skip empty or very short audio.
        guard !audioBuffer.data.isEmpty, audioBuffer.duration >= minimumAudioDuration else {
            debugPrint(
                "[Pipeline] Audio too short (\(audioBuffer.duration)s), skipping dictation")
            await coordinator.reset()
            return nil
        }

        // Reject silent or noise-only audio before sending to the server.
        if AudioLevelAnalyzer.isSilent(audioBuffer, threshold: silenceThreshold) {
            let rms = AudioLevelAnalyzer.rmsLevel(of: audioBuffer)
            debugPrint(
                "[Pipeline] Audio below silence threshold "
                    + "(rms: \(rms), threshold: \(silenceThreshold)), skipping dictation")
            await coordinator.reset()
            return nil
        }

        guard !Task.isCancelled else {
            await coordinator.reset()
            return nil
        }

        // Send audio + context to the dictation service.
        do {
            let text = try await dictationProvider.dictate(
                audio: audioBuffer.data, context: context)
            return text
        } catch {
            debugPrint("[Pipeline] Dictation failed: \(error)")
            await coordinator.reset()
            return nil
        }
    }
}
