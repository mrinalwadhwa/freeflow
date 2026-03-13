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

    /// Called when a dictation request fails with a 401 authentication
    /// error. The app should clear stored credentials and enter the
    /// session recovery flow. Invoked at most once per pipeline run.
    private let onSessionExpired: (@Sendable () -> Void)?

    /// Minimum audio duration (in seconds) worth sending to the server.
    private let minimumAudioDuration: TimeInterval = 0.1

    /// Fixed RMS silence threshold, used as a fallback when ambient
    /// calibration has not completed (recording shorter than 0.5s).
    /// When ambient RMS is available and the mic is near-field, the
    /// pipeline computes an adaptive threshold instead:
    /// `max(ambientRMS * 1.2, 0.0005)`. For far-field (built-in) mics,
    /// the adaptive threshold is skipped because speech and ambient RMS
    /// are virtually indistinguishable (ratio as low as 1.0–1.2x); the
    /// server's `input_audio_noise_reduction: far_field` handles signal
    /// quality instead.
    private let silenceThreshold: Float

    /// Fixed threshold for far-field (built-in) mics. Much lower than
    /// the default `silenceThreshold` because built-in mic speech peaks
    /// at only 0.002–0.005 RMS. Set just above the absolute noise floor
    /// to reject truly silent presses without blocking quiet speech.
    private let farFieldSilenceThreshold: Float = 0.001

    /// Multiplier applied to the measured ambient RMS to produce an
    /// adaptive silence threshold. Speech must exceed ambient × this
    /// factor to be considered non-silent. 1.2 is calibrated from
    /// real-world testing: built-in mic speech/ambient ratio can be
    /// as low as 1.2x in quiet rooms (previous multipliers of 2.0
    /// and 1.5 both rejected real speech on the built-in mic). The
    /// silence gate only needs to reject truly silent presses; the
    /// server's far-field noise reduction handles signal quality.
    /// AirPods ambient (~0.002) → threshold 0.0024, still well
    /// below AirPods speech RMS (~0.08).
    private let ambientMultiplier: Float = 1.2

    /// Absolute floor for the adaptive threshold. Even with zero
    /// measured ambient noise, reject audio below this level.
    private let minimumAdaptiveThreshold: Float = 0.0005

    /// Ceiling for the adaptive threshold. AirPods noise cancellation
    /// can produce variable ambient RMS (0.002–0.015) depending on
    /// environment. Without a cap, high ambient pushes the threshold
    /// above whisper peak RMS (~0.009) and silently rejects speech.
    /// 0.01 lets whispers through while still rejecting noise-only
    /// presses (which peak well below 0.005 on near-field mics).
    private let maximumAdaptiveThreshold: Float = 0.01

    /// Context captured concurrently during the recording phase.
    private var pendingContext: Task<AppContext, Never>?

    /// The in-flight pipeline task, used for cancellation.
    private var pipelineTask: Task<Void, Never>?

    /// Background task that forwards PCM chunks to the streaming provider.
    private var audioForwardingTask: Task<Void, Never>?

    /// Task that performs audio setup after activate() returns.
    /// complete() awaits this to ensure audio is ready before stopping.
    private var audioSetupTask: Task<Void, Never>?

    /// Whether the current recording session is using streaming mode.
    private var isStreamingSession: Bool = false

    /// ISO-639-1 language hint for transcription (e.g. "en", "fr", "ja").
    /// Set from the menu bar language picker or auto-detected from macOS
    /// locale. When nil, the server defaults to auto-detection.
    private(set) var language: String?

    /// Update the language hint from outside the actor.
    public func setLanguage(_ code: String?) {
        language = code
    }

    public init(
        audioProvider: AudioProviding,
        contextProvider: AppContextProviding,
        dictationProvider: DictationProviding,
        textInjector: TextInjecting,
        coordinator: RecordingCoordinator,
        transcriptBuffer: TranscriptBuffer? = nil,
        silenceThreshold: Float = 0.005,
        streamingProvider: StreamingDictationProviding? = nil,
        onSessionExpired: (@Sendable () -> Void)? = nil
    ) {
        self.audioProvider = audioProvider
        self.contextProvider = contextProvider
        self.dictationProvider = dictationProvider
        self.textInjector = textInjector
        self.coordinator = coordinator
        self.transcriptBuffer = transcriptBuffer
        self.silenceThreshold = silenceThreshold
        self.streamingProvider = streamingProvider
        self.onSessionExpired = onSessionExpired
    }

    /// Compute the effective silence threshold for the current session.
    ///
    /// For far-field (built-in) mics, returns a low fixed threshold
    /// because speech and ambient RMS are virtually indistinguishable
    /// (ratio 1.0–1.2x). The server's far-field noise reduction handles
    /// signal quality, so the silence gate only needs to reject truly
    /// silent presses.
    ///
    /// For near-field mics (AirPods, USB, etc.), uses an adaptive
    /// threshold based on ambient noise when calibration has completed.
    /// Otherwise falls back to the fixed `silenceThreshold`.
    private func effectiveSilenceThreshold() -> Float {
        // Built-in mic: skip adaptive threshold entirely.
        if audioProvider.micProximity == .farField {
            return farFieldSilenceThreshold
        }
        // Near-field mic: use adaptive threshold when ambient is known.
        // Clamp between floor and ceiling so variable ambient (e.g.
        // AirPods noise cancellation adjusting) cannot push the
        // threshold above whisper-range speech.
        let ambient = audioProvider.ambientRMS
        if ambient > 0 {
            let raw = ambient * ambientMultiplier
            return min(max(raw, minimumAdaptiveThreshold), maximumAdaptiveThreshold)
        }
        return silenceThreshold
    }

    // MARK: - PipelineProviding

    public var state: RecordingState {
        get async {
            await coordinator.state
        }
    }

    public func activate() async {
        let t0 = CFAbsoluteTimeGetCurrent()
        let currentState = await coordinator.state
        guard currentState == .idle else {
            Log.debug("[Pipeline] activate() ignored — state is \(currentState)")
            return
        }

        let t1 = CFAbsoluteTimeGetCurrent()
        let started = await coordinator.startRecording()
        guard started else { return }
        let t2 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] activate() state check: \(String(format: "%.3f", t1 - t0))s, startRecording: \(String(format: "%.3f", t2 - t1))s"
        )

        // State is now .recording — return immediately so the HUD can animate.
        // Audio setup runs in a detached task so it does not execute on the
        // pipeline actor's executor. A plain Task inherits the actor context
        // and can block the actor until the first suspension point, which
        // delays the return from activate() by the full AVAudioEngine start
        // time (0.5-0.9s). Detached tasks run independently, letting
        // activate() return instantly and the HUD expand without delay.
        let pipeline = self
        audioSetupTask = Task.detached {
            await pipeline.performAudioSetup(activationTime: t0)
        }
    }

    /// Perform audio capture setup and streaming initialization.
    /// This runs after `activate()` returns, so the HUD can animate immediately.
    private func performAudioSetup(activationTime t0: CFAbsoluteTime) async {
        // Bail early if cancelled before we even begin (e.g. rapid cancel
        // after activate). Without this check the detached task can start
        // recording after cancel() has already finished its cleanup.
        guard !Task.isCancelled else {
            Log.debug("[Pipeline] performAudioSetup() cancelled before start")
            return
        }

        // Start reading context concurrently. The result is awaited in complete().
        let ctxProvider = contextProvider
        pendingContext = Task {
            await ctxProvider.readContext()
        }

        // Start audio capture. This can take 500-900ms due to AVAudioEngine
        // setup. The UI is already showing "listening" state since
        // activate() returned.
        //
        // IMPORTANT: audioProvider.startRecording() runs engine.start()
        // inside a synchronous lock. When the default input device is a
        // Bluetooth device (AirPods), engine.start() can block for
        // seconds while macOS negotiates the SCO audio channel. Because
        // performAudioSetup() is an actor-isolated method, a blocking
        // call here monopolises the pipeline actor's executor — no other
        // actor method (complete(), cancel()) can run until it returns,
        // which freezes the hotkey entirely.
        //
        // Fix: run startRecording() in a detached task so it blocks a
        // cooperative-pool thread instead of the actor. The actor awaits
        // the result via withCheckedContinuation, which suspends (not
        // blocks) the actor. A 3s timeout catches hangs during BT
        // negotiation and lets the pipeline fall back to batch mode.
        let t3 = CFAbsoluteTimeGetCurrent()
        let audioProviderRef = audioProvider
        enum StartRecordingTimeout: Error { case timedOut }
        let startResult: Result<Void, Error> = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            // Worker: run startRecording() off the actor.
            Task.detached {
                do {
                    try await audioProviderRef.startRecording()
                    let alreadyResumed = lock.withLock {
                        let was = resumed
                        resumed = true
                        return was
                    }
                    if !alreadyResumed {
                        continuation.resume(returning: .success(()))
                    }
                } catch {
                    let alreadyResumed = lock.withLock {
                        let was = resumed
                        resumed = true
                        return was
                    }
                    if !alreadyResumed {
                        continuation.resume(returning: .failure(error))
                    }
                }
            }

            // Timeout: 3s ceiling for BT SCO negotiation.
            Task.detached {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let alreadyResumed = lock.withLock {
                    let was = resumed
                    resumed = true
                    return was
                }
                if !alreadyResumed {
                    Log.debug(
                        "[Pipeline] startRecording() timed out (3s), likely BT negotiation hang"
                    )
                    continuation.resume(returning: .failure(StartRecordingTimeout.timedOut))
                }
            }
        }

        switch startResult {
        case .success:
            break
        case .failure(let error):
            Log.debug("[Pipeline] Failed to start recording: \(error)")
            // If startRecording() timed out, the background task may
            // finish and leave _isRecording=true permanently. Stop it
            // so the next session can start cleanly.
            Task { [audioProvider] in
                _ = try? await audioProvider.stopRecording()
            }
            pendingContext?.cancel()
            pendingContext = nil
            await coordinator.reset()
            return
        }

        // Check cancellation after starting audio. cancel() may have fired
        // while startRecording() was in progress. Without this, the audio
        // provider stays in the recording state with no one to stop it,
        // causing testCancelFromRecordingResetsToIdle to flake.
        if Task.isCancelled {
            Log.debug("[Pipeline] performAudioSetup() cancelled after startRecording")
            _ = try? await audioProvider.stopRecording()
            pendingContext?.cancel()
            pendingContext = nil
            return
        }
        let t4 = CFAbsoluteTimeGetCurrent()
        Log.debug(
            "[Pipeline] performAudioSetup() audioProvider.startRecording: \(String(format: "%.3f", t4 - t3))s"
        )

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

            let t5 = CFAbsoluteTimeGetCurrent()
            let micProximity = audioProvider.micProximity
            let language = self.language

            // Timeout the streaming setup to avoid blocking complete()
            // indefinitely. ensureConnected()/sendPing can hang when the
            // WebSocket is in a broken state. On timeout we cancel the
            // streaming session and fall back to batch mode.
            //
            // Uses a single detached task with an internal task-group
            // timeout. This avoids zombie detached tasks that pile up
            // when the timeout fires but startStreaming() keeps retrying
            // ensureConnected() in the background.
            Log.debug(
                "[Pipeline] Starting streaming setup with 5s timeout (language=\(language ?? "nil"))"
            )
            let streamingStarted: Bool = await Task.detached {
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        do {
                            Log.debug("[Pipeline] streaming.startStreaming() entering")
                            try await streaming.startStreaming(
                                context: context, language: language,
                                micProximity: micProximity)
                            Log.debug("[Pipeline] streaming.startStreaming() returned OK")
                            return true
                        } catch {
                            Log.debug("[Pipeline] streaming.startStreaming() failed: \(error)")
                            return false
                        }
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5s
                        Log.debug("[Pipeline] Streaming setup timeout fired")
                        return false
                    }
                    let first = await group.next() ?? false
                    // Cancel the losing task. If the timeout won, this
                    // cancels startStreaming() so it won't keep retrying
                    // ensureConnected() as a zombie. If startStreaming()
                    // won, this just cancels the sleeping timeout task.
                    group.cancelAll()
                    return first
                }
            }.value

            // If streaming timed out, also cancel the session on the
            // provider so it tears down the broken connection cleanly
            // rather than leaving stale state for the next session.
            if !streamingStarted {
                await streaming.cancelStreaming()
            }

            guard streamingStarted else {
                Log.debug("[Pipeline] Streaming setup timed out or failed, falling back to batch")
                isStreamingSession = false
                return
            }
            let t6 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] performAudioSetup() streaming.startStreaming: \(String(format: "%.3f", t6 - t5))s, total: \(String(format: "%.3f", t6 - t0))s"
            )

            // Start a background task that reads PCM chunks and sends them.
            audioForwardingTask = Task {
                for await chunk in pcmStream {
                    guard !Task.isCancelled else { break }
                    do {
                        try await streaming.sendAudio(chunk)
                    } catch {
                        Log.debug("[Pipeline] Error sending audio chunk: \(error)")
                        break
                    }
                }
            }
        } else {
            isStreamingSession = false
        }
    }

    public func complete() async {
        Log.debug("[Pipeline] complete() entering")
        let currentState = await coordinator.state
        guard currentState == .recording else {
            Log.debug("[Pipeline] complete() ignored — state is \(currentState)")
            return
        }

        Log.debug("[Pipeline] complete() transitioning to processing")
        let stopped = await coordinator.stopRecording()
        guard stopped else { return }

        // If audio setup is still in progress, give it a short window
        // to finish (covers the normal 500-900ms AVAudioEngine start).
        // If it doesn't complete in time, cancel it and fall back to
        // batch mode — we already have the audio buffer from the
        // capture that did start.
        //
        // IMPORTANT: We cannot use `await setupTask.value` directly or
        // inside a TaskGroup, because the setup task runs on this actor
        // and may be blocked on a non-cancellable operation (e.g.
        // URLSession sendPing). TaskGroup.cancelAll() doesn't unblock
        // children that are stuck in non-cancellable awaits, and the
        // group won't return until all children exit. Instead we use a
        // detached polling loop that checks whether the task has set
        // `isStreamingSession` or completed, with a hard 6s deadline.
        // If the audio is clearly silent, skip the streaming setup wait
        // entirely. peakRMS is updated by the tap callback during
        // recording, so it reflects the loudest moment. When it is below
        // the silence threshold, there is nothing to transcribe and
        // waiting 5-6s for a stale WebSocket ping to time out is waste.
        let earlyThreshold = effectiveSilenceThreshold()
        if audioProvider.peakRMS <= earlyThreshold {
            if let setupTask = audioSetupTask {
                setupTask.cancel()
                if let streaming = streamingProvider {
                    await streaming.cancelStreaming()
                }
                audioSetupTask = nil
            }
            isStreamingSession = false
            audioForwardingTask?.cancel()
            audioForwardingTask = nil

            Log.debug(
                "[Pipeline] Early silence short-circuit: peak RMS \(audioProvider.peakRMS) <= \(earlyThreshold) (ambient: \(audioProvider.ambientRMS)), skipping setup wait"
            )

            // Stop audio and reset immediately.
            _ = try? await audioProvider.stopRecording()
            await coordinator.reset()
            return
        }

        if let setupTask = audioSetupTask {
            let setupDone: Bool = await withCheckedContinuation { continuation in
                let lock = NSLock()
                var resumed = false

                // Monitor task: polls for completion by trying to get
                // the value from a detached context (no actor dependency).
                Task.detached { [weak self] in
                    await setupTask.value
                    let alreadyResumed = lock.withLock {
                        let was = resumed
                        resumed = true
                        return was
                    }
                    if !alreadyResumed {
                        continuation.resume(returning: true)
                    }
                }

                // Timeout task: poll for silence or hard 6s ceiling.
                // When the audio is clearly silent, bail after a short
                // window (200ms) instead of waiting the full 6s for a
                // stale WebSocket ping to time out. peakRMS is updated
                // by the tap callback on the audio render thread so it
                // is safe to read from a detached task via the lock in
                // AudioCaptureProvider.
                Task.detached { [audioProvider, earlyThreshold] in
                    let deadline = Date().addingTimeInterval(6.0)
                    var silentTicks = 0
                    while Date() < deadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        let alreadyDone = lock.withLock { resumed }
                        if alreadyDone { return }

                        if audioProvider.peakRMS <= earlyThreshold {
                            silentTicks += 1
                            // 4 ticks × 50ms = 200ms of confirmed silence
                            if silentTicks >= 4 {
                                Log.debug(
                                    "[Pipeline] Setup wait bailing early: silent audio (peak RMS \(audioProvider.peakRMS), threshold \(earlyThreshold))"
                                )
                                break
                            }
                        } else {
                            silentTicks = 0
                        }
                    }
                    let alreadyResumed = lock.withLock {
                        let was = resumed
                        resumed = true
                        return was
                    }
                    if !alreadyResumed {
                        setupTask.cancel()
                        continuation.resume(returning: false)
                    }
                }
            }

            if setupDone {
                Log.debug("[Pipeline] complete() audio setup finished normally")
            } else {
                Log.debug("[Pipeline] complete() audio setup timed out, cancelling")
                // Give the streaming provider a clean teardown so it
                // doesn't leave broken connection state.
                if let streaming = streamingProvider {
                    await streaming.cancelStreaming()
                }
                isStreamingSession = false
            }
            audioSetupTask = nil
        }

        let useStreaming = isStreamingSession
        let forwardingTask = audioForwardingTask
        audioForwardingTask = nil
        isStreamingSession = false

        let task = Task {
            [
                pendingContext, audioProvider, dictationProvider, streamingProvider,
                textInjector, coordinator, minimumAudioDuration, transcriptBuffer,
                earlyThreshold
            ] in
            let t0 = CFAbsoluteTimeGetCurrent()

            // Stop audio capture and retrieve the buffer.
            Log.debug("[Pipeline] stopping audio capture")
            let audioBuffer: AudioBuffer
            do {
                audioBuffer = try await audioProvider.stopRecording()
            } catch {
                Log.debug("[Pipeline] Failed to stop recording: \(error)")
                if useStreaming, let streaming = streamingProvider {
                    forwardingTask?.cancel()
                    await streaming.cancelStreaming()
                }
                await coordinator.reset()
                return
            }

            let t1 = CFAbsoluteTimeGetCurrent()
            Log.debug(
                "[Pipeline] audio stopped (\(String(format: "%.2f", audioBuffer.duration))s, \(audioBuffer.data.count)B)"
            )

            // Early silence check: use the peak RMS tracked during
            // recording to reject silent presses immediately, before
            // waiting on the streaming forwarding task or any network
            // calls. This avoids the 5-7s delay users see when they
            // tap the hotkey without speaking.
            // Recompute the threshold now that ambient calibration may
            // have finished during recording. Use effectiveSilenceThreshold()
            // which respects far-field mic proximity (built-in mics use
            // a low fixed threshold instead of the adaptive calculation).
            let postRecordThreshold = effectiveSilenceThreshold()

            let peakLevel = audioProvider.peakRMS
            if peakLevel <= postRecordThreshold {
                Log.debug(
                    "[Pipeline] Early silence gate: peak RMS \(peakLevel) <= \(postRecordThreshold) (ambient: \(audioProvider.ambientRMS)), skipping"
                )
                forwardingTask?.cancel()
                if useStreaming, let streaming = streamingProvider {
                    await streaming.cancelStreaming()
                }
                await coordinator.reset()
                return
            }

            // Wait for the audio forwarding task to finish. The PCM stream
            // ends when stopRecording() calls pcmContinuation.finish(), so
            // normally this returns immediately. However, if the forwarding
            // task is stuck in sendAudio() on a broken WebSocket,
            // URLSessionWebSocketTask.send() ignores cancellation. Use a
            // detached-task timeout to bound the wait. If it hangs, cancel
            // the streaming session (which cancels the WebSocket task and
            // forces send() to throw) and proceed with batch mode.
            if let ft = forwardingTask {
                ft.cancel()
                let forwardingDone: Bool = await withCheckedContinuation { continuation in
                    let lock = NSLock()
                    var resumed = false
                    Task.detached {
                        await ft.value
                        let alreadyResumed = lock.withLock {
                            let was = resumed
                            resumed = true
                            return was
                        }
                        if !alreadyResumed {
                            continuation.resume(returning: true)
                        }
                    }
                    Task.detached {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let alreadyResumed = lock.withLock {
                            let was = resumed
                            resumed = true
                            return was
                        }
                        if !alreadyResumed {
                            continuation.resume(returning: false)
                        }
                    }
                }
                if !forwardingDone {
                    Log.debug(
                        "[Pipeline] audio forwarding task timed out (2s), cancelling streaming")
                    if useStreaming, let streaming = streamingProvider {
                        await streaming.cancelStreaming()
                    }
                }
            }

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
                // Streaming mode: run streaming and batch in parallel.
                // Use whichever returns successfully first. This avoids
                // the 10s delay when streaming fails and we fall back to batch.
                Log.debug("[Pipeline] finishing streaming session (with parallel batch)")

                let streamingResult = await raceStreamingAndBatch(
                    streaming: streaming,
                    audioBuffer: audioBuffer,
                    context: context,
                    dictationProvider: dictationProvider,
                    minimumAudioDuration: minimumAudioDuration,
                    silenceThreshold: postRecordThreshold,
                    language: self.language
                )

                guard let text = streamingResult else {
                    Log.debug("[Pipeline] Both streaming and batch failed")
                    await coordinator.reset()
                    return
                }
                dictatedText = text
            } else {
                // Batch mode: send the complete audio buffer to /dictate.
                Log.debug("[Pipeline] batch mode, sending to dictation service")

                let batchResult = await batchDictate(
                    audioBuffer: audioBuffer,
                    context: context,
                    dictationProvider: dictationProvider,
                    minimumAudioDuration: minimumAudioDuration,
                    silenceThreshold: postRecordThreshold,
                    coordinator: coordinator
                )
                guard let text = batchResult else { return }
                dictatedText = text
            }

            let t4 = CFAbsoluteTimeGetCurrent()
            Log.debug("[Pipeline] dictation returned, injecting text")

            // Skip injection for empty or whitespace-only text.
            let finalText = dictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                Log.debug("[Pipeline] Empty dictation result, skipping injection")
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
                Log.debug("[Pipeline] Text injection failed: \(error)")
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
            Log.debug(
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

        // Bound the entire pipeline task to 15s. If it hangs (stuck
        // WebSocket send, server not responding, etc.), cancel it and
        // force-reset to idle so the user can try again. Without this,
        // a hang inside the task permanently leaves the pipeline in
        // .processing and all subsequent activate()/complete() calls
        // are ignored.
        let pipelineDone: Bool = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            Task.detached {
                await task.value
                let alreadyResumed = lock.withLock {
                    let was = resumed
                    resumed = true
                    return was
                }
                if !alreadyResumed {
                    continuation.resume(returning: true)
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                let alreadyResumed = lock.withLock {
                    let was = resumed
                    resumed = true
                    return was
                }
                if !alreadyResumed {
                    task.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
        if !pipelineDone {
            Log.debug(
                "[Pipeline] complete() pipeline task timed out (15s), force-resetting to idle")
            if let streaming = streamingProvider {
                await streaming.cancelStreaming()
            }
            await coordinator.reset()
        }
        self.pipelineTask = nil
    }

    public func cancel() async {
        pipelineTask?.cancel()
        pipelineTask = nil
        pendingContext?.cancel()
        pendingContext = nil

        audioSetupTask?.cancel()
        audioSetupTask = nil

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

    // MARK: - Parallel Streaming + Batch

    /// Race streaming and batch dictation in parallel.
    ///
    /// Start both paths concurrently and return the result from whichever
    /// succeeds first. If streaming wins, cancel the batch task. If batch
    /// wins (streaming timed out or failed), use the batch result.
    ///
    /// Returns nil if both paths fail. When the batch HTTP path returns a
    /// 401 auth error, the pipeline transitions to `.sessionExpired` and
    /// invokes the `onSessionExpired` callback before returning nil.
    private func raceStreamingAndBatch(
        streaming: StreamingDictationProviding,
        audioBuffer: AudioBuffer,
        context: AppContext,
        dictationProvider: DictationProviding,
        minimumAudioDuration: TimeInterval,
        silenceThreshold: Float,
        language: String? = nil
    ) async -> String? {
        // Check audio validity before starting either path.
        guard !audioBuffer.data.isEmpty, audioBuffer.duration >= minimumAudioDuration else {
            Log.debug(
                "[Pipeline] Audio too short (\(audioBuffer.duration)s), skipping dictation")
            return nil
        }

        // Reject silent or noise-only audio before sending to either path.
        // AirPods noise cancellation can produce a subtle floor of sound
        // that the Realtime API misinterprets as speech (e.g. "You.",
        // "Thanks for watching!"). The client-side silence gate catches this.
        let rms = AudioLevelAnalyzer.rmsLevel(of: audioBuffer)
        Log.debug(
            "[Pipeline] Audio RMS: \(rms), threshold: \(silenceThreshold), "
                + "duration: \(String(format: "%.2f", audioBuffer.duration))s")
        if rms <= silenceThreshold {
            Log.debug(
                "[Pipeline] Audio below silence threshold, skipping dictation")
            return nil
        }

        // Extract raw PCM data from the WAV buffer for the backup path.
        // The AudioBuffer contains a WAV file (44-byte RIFF header + PCM).
        // The backup WebSocket expects raw PCM chunks, not WAV.
        let pcmData: Data
        if audioBuffer.data.count > 44 {
            pcmData = audioBuffer.data.subdata(in: 44..<audioBuffer.data.count)
        } else {
            pcmData = audioBuffer.data
        }

        let t0 = CFAbsoluteTimeGetCurrent()

        // Thread-safe box to propagate an auth-error flag out of the
        // continuation closure. The detached tasks write to it under
        // its internal lock; the outer scope reads it after the
        // continuation returns (by which time both tasks have finished).
        final class AuthErrorFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var _value = false
            func set() { lock.withLock { _value = true } }
            var isSet: Bool { lock.withLock { _value } }
        }
        let authError = AuthErrorFlag()

        // Race streaming (primary) and backup WebSocket with true
        // first-to-finish semantics.
        //
        // The backup path runs a full session on the standby WebSocket
        // (start → audio → stop → transcript_done) instead of the
        // slower HTTP batch POST. Expected latency: 0.3–0.9s (backup)
        // vs 1–2.5s (batch HTTP).
        //
        // If the backup is not available (nil, no connection), fall back
        // to batch HTTP. This should be rare since both independent
        // WebSocket connections dying simultaneously is unlikely.
        //
        // We use detached tasks + a checked continuation because
        // structured concurrency (TaskGroup, async let) waits for ALL
        // children before the scope exits, even after cancelAll(). If
        // one child is stuck in a non-cancellable await (e.g.
        // URLSessionWebSocketTask.receive()), the group blocks forever.
        // Detached tasks have no such constraint — the continuation
        // resumes as soon as either task delivers a result.
        let winner: String? = await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            var streamingResult: String?
            var fallbackResult: String?
            var gotStreaming = false
            var gotFallback = false

            func tryResume(preferredText: String?, source: String) {
                let alreadyResumed = lock.withLock {
                    let was = resumed
                    if !was { resumed = true }
                    return was
                }
                if !alreadyResumed {
                    let t1 = CFAbsoluteTimeGetCurrent()
                    Log.debug(
                        "[Pipeline] Using \(source) result (\(String(format: "%.2f", t1 - t0))s)")
                    continuation.resume(returning: preferredText)
                }
            }

            func checkBothDone() {
                // Called after one path finishes. If both paths finished
                // but neither had usable text, resume with whatever we have.
                let (done, sr, fr): (Bool, String?, String?) = lock.withLock {
                    (gotStreaming && gotFallback, streamingResult, fallbackResult)
                }
                guard done else { return }
                let fallback = sr ?? fr
                let alreadyResumed = lock.withLock {
                    let was = resumed
                    if !was { resumed = true }
                    return was
                }
                if !alreadyResumed {
                    let t1 = CFAbsoluteTimeGetCurrent()
                    Log.debug(
                        "[Pipeline] Both paths done, no winner (\(String(format: "%.2f", t1 - t0))s)"
                    )
                    continuation.resume(returning: fallback)
                }
            }

            let streamingTask = Task.detached {
                do {
                    let result = try await streaming.finishStreaming()
                    Log.debug("[Pipeline] Streaming completed")
                    lock.withLock {
                        streamingResult = result
                        gotStreaming = true
                    }
                    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tryResume(preferredText: result, source: "streaming")
                    } else {
                        checkBothDone()
                    }
                } catch {
                    Log.debug("[Pipeline] Streaming failed: \(error)")
                    lock.withLock {
                        streamingResult = nil
                        gotStreaming = true
                    }
                    checkBothDone()
                }
            }

            // Fallback path: try backup WebSocket first, then batch HTTP.
            let fallbackTask = Task.detached {
                // Attempt the backup WebSocket path first. This runs a
                // full session on the standby connection (~0.3–0.9s).
                do {
                    let result = try await streaming.dictateViaBackup(
                        audio: pcmData, context: context, language: language)
                    Log.debug("[Pipeline] Backup dictation completed")
                    lock.withLock {
                        fallbackResult = result
                        gotFallback = true
                    }
                    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tryResume(preferredText: result, source: "backup")
                    } else {
                        checkBothDone()
                    }
                    return
                } catch {
                    Log.debug(
                        "[Pipeline] Backup dictation failed: \(error), falling back to batch HTTP")
                }

                // Backup unavailable or failed — fall back to batch HTTP.
                do {
                    let result = try await dictationProvider.dictate(
                        audio: audioBuffer.data, context: context)
                    Log.debug("[Pipeline] Batch HTTP completed")
                    lock.withLock {
                        fallbackResult = result
                        gotFallback = true
                    }
                    if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tryResume(preferredText: result, source: "batch")
                    } else {
                        checkBothDone()
                    }
                } catch let error as DictationError where error == .authenticationFailed {
                    Log.debug("[Pipeline] Batch HTTP returned 401")
                    authError.set()
                    lock.withLock {
                        fallbackResult = nil
                        gotFallback = true
                    }
                    checkBothDone()
                } catch {
                    Log.debug("[Pipeline] Batch HTTP failed: \(error)")
                    lock.withLock {
                        fallbackResult = nil
                        gotFallback = true
                    }
                    checkBothDone()
                }
            }

            // Suppress unused variable warnings. The tasks are kept
            // alive by the closures capturing the continuation; we
            // don't need to explicitly cancel the loser because the
            // extra network call is acceptable for reliability.
            _ = streamingTask
            _ = fallbackTask
        }

        // The batch HTTP path is the definitive 401 signal. WebSocket
        // paths surface auth failures as generic connection errors
        // (close code 4001), but the batch endpoint returns a clean
        // HTTP 401 that the provider maps to .authenticationFailed.
        if authError.isSet && winner == nil {
            await notifySessionExpired()
            return nil
        }

        return winner
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
            Log.debug(
                "[Pipeline] Audio too short (\(audioBuffer.duration)s), skipping dictation")
            await coordinator.reset()
            return nil
        }

        // Reject silent or noise-only audio before sending to the server.
        if AudioLevelAnalyzer.isSilent(audioBuffer, threshold: silenceThreshold) {
            let rms = AudioLevelAnalyzer.rmsLevel(of: audioBuffer)
            Log.debug(
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
        } catch let error as DictationError where error == .authenticationFailed {
            Log.debug("[Pipeline] Dictation returned 401, session expired")
            await notifySessionExpired()
            return nil
        } catch {
            Log.debug("[Pipeline] Dictation failed: \(error)")
            await coordinator.reset()
            return nil
        }
    }

    // MARK: - Session expiry

    /// Transition the coordinator to `.sessionExpired` and invoke the
    /// callback so the app can clear credentials and start recovery.
    private func notifySessionExpired() async {
        await coordinator.expireSession()
        onSessionExpired?()
    }
}
