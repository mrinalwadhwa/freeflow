import XCTest

@testable import VoiceKit

final class StreamingPipelineTests: XCTestCase {

    // MARK: - Helpers

    /// Build a MockAudioProvider that supports PCM streaming by default.
    private func makeStreamingAudioProvider() -> MockAudioProvider {
        let audio = MockAudioProvider()
        audio.enablePCMStream = true
        return audio
    }

    /// Build raw 16-bit PCM data with alternating ±3000 samples.
    private func makeNonSilentPCMChunk(sampleCount: Int = 1600) -> Data {
        var data = Data(capacity: sampleCount * 2)
        for i in 0..<sampleCount {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Build a slow batch mock so streaming wins the race by default.
    /// Tests that need batch to win pass their own fast MockDictationProvider.
    private func makeSlowBatchProvider() -> MockDictationProvider {
        let batch = MockDictationProvider()
        batch.stubbedDelay = 5.0
        return batch
    }

    private func makeStreamingPipeline(
        audioProvider: MockAudioProvider? = nil,
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        dictationProvider: MockDictationProvider? = nil,
        streamingProvider: MockStreamingDictationProvider = MockStreamingDictationProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer? = nil
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider,
        MockDictationProvider, MockStreamingDictationProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let audio = audioProvider ?? makeStreamingAudioProvider()
        let dictation = dictationProvider ?? makeSlowBatchProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: contextProvider,
            dictationProvider: dictation,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer,
            streamingProvider: streamingProvider
        )
        return (
            pipeline, audio, contextProvider, dictation,
            streamingProvider, textInjector, coordinator
        )
    }

    /// Emit PCM chunks in the background so the forwarding task has data.
    private func emitChunksInBackground(
        _ audio: MockAudioProvider,
        count: Int = 2,
        sampleCount: Int = 1600,
        delayNanos: UInt64 = 20_000_000
    ) -> Task<Void, Never> {
        let chunks = (0..<count).map { _ in makeNonSilentPCMChunk(sampleCount: sampleCount) }
        return Task {
            for chunk in chunks {
                guard !Task.isCancelled else { break }
                audio.emitPCMChunk(chunk)
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    // MARK: - Full streaming cycle

    func testStreamingFullCycleTransitionsToIdleAfterCompletion() async {
        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline()

        await pipeline.activate()
        var state = await coordinator.state
        XCTAssertEqual(state, .recording)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testStreamingFullCycleInjectsText() async {
        let streaming = MockStreamingDictationProvider(stubbedText: "Hello streaming")
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "Hello streaming")
    }

    func testStreamingFullCycleStartsAndStopsAudioCapture() async {
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the setup task to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertTrue(audio.isRecording)

        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertFalse(audio.isRecording)
    }

    func testStreamingFullCycleCallsStartStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.startCallCount, 1)
    }

    func testStreamingFullCycleCallsFinishStreaming() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.finishCallCount, 1)
    }

    func testStreamingFullCycleForwardsAudioChunks() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()

        // Emit chunks and give the forwarding task time to process.
        let emitTask = emitChunksInBackground(audio, count: 3)
        try? await Task.sleep(nanoseconds: 150_000_000)
        emitTask.cancel()

        await pipeline.complete()

        XCTAssertGreaterThan(
            streaming.sendCallCount, 0,
            "Audio chunks should be forwarded to the streaming provider")
        XCTAssertGreaterThan(
            streaming.totalAudioBytesReceived, 0,
            "Streaming provider should receive audio data")
    }

    func testStreamingRunsBatchInParallel() async {
        // With parallel batch, both streaming and batch are called.
        // This test verifies that batch is called alongside streaming.
        let (pipeline, audio, _, dictation, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called in parallel with streaming")
    }

    func testStreamingReadsContext() async {
        let (pipeline, audio, context, _, _, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(context.readContextCallCount, 1)
    }

    func testStreamingPassesContextToStartStreaming() async {
        let ctx = AppContext(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: "Test Window"
        )
        let contextProvider = MockAppContextProvider(context: ctx)
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline(
            contextProvider: contextProvider)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.receivedContexts.count, 1)
        let received = streaming.receivedContexts.first
        XCTAssertEqual(received?.bundleID, "com.test.app")
        XCTAssertEqual(received?.appName, "TestApp")
    }

    func testStreamingPassesContextToTextInjector() async {
        let ctx = AppContext(
            bundleID: "com.test.inject",
            appName: "InjectApp",
            windowTitle: "Inject Window"
        )
        let contextProvider = MockAppContextProvider(context: ctx)
        let (pipeline, audio, _, _, _, injector, _) = makeStreamingPipeline(
            contextProvider: contextProvider)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let injectedContext = injector.injections.first?.context
        XCTAssertEqual(injectedContext?.bundleID, "com.test.inject")
        XCTAssertEqual(injectedContext?.appName, "InjectApp")
    }

    // MARK: - State transitions

    func testStreamingStatePassesThroughAllPhases() async {
        let coordinator = RecordingCoordinator()
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                // idle, recording, processing, injecting, idle
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .idle])
    }

    // MARK: - Cancellation

    func testCancelDuringStreamingResetsToIdle() async {
        let (pipeline, _, _, _, streaming, _, coordinator) = makeStreamingPipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the streaming session to start before cancelling.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        let state = await coordinator.state
        XCTAssertEqual(state, .recording)

        await pipeline.cancel()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        XCTAssertEqual(
            streaming.cancelCallCount, 1,
            "Streaming session should be cancelled")
    }

    func testCancelDoesNotCallFinishStreaming() async {
        let (pipeline, _, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        await pipeline.cancel()

        XCTAssertEqual(
            streaming.finishCallCount, 0,
            "finishStreaming should not be called on cancel")
    }

    func testCycleWorksAfterStreamingCancel() async {
        let streaming = MockStreamingDictationProvider(stubbedText: "After cancel")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming)

        // First cycle: cancel.
        await pipeline.activate()
        await pipeline.cancel()
        var state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: complete.
        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(streaming.finishCallCount, 1)
    }

    // MARK: - Streaming errors

    func testStreamingStartFailureFallsToBatchMode() async {
        let streaming = MockStreamingDictationProvider()
        streaming.stubbedStartError = DictationError.networkError("connection refused")

        let dictation = MockDictationProvider(stubbedText: "Batch fallback text")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // When streaming start fails, pipeline falls back to batch mode.
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called as fallback when streaming start fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch fallback text")
    }

    func testStreamingFinishFailureFallsToBatch() async {
        let streaming = MockStreamingDictationProvider()
        streaming.stubbedFinishError = DictationError.networkError("connection lost")

        let dictation = MockDictationProvider(stubbedText: "Batch recovery")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be called as fallback when streaming finish fails")
        XCTAssertEqual(injector.lastInjectedText, "Batch recovery")
    }

    func testStreamingEmptyResultUsesBatchFallback() async {
        // When streaming returns empty, batch result is used (parallel mode).
        let streaming = MockStreamingDictationProvider(stubbedText: "")
        let dictation = MockDictationProvider(stubbedText: "Batch result")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 1,
            "Batch result should be injected when streaming returns empty")
        XCTAssertEqual(injector.lastInjectedText, "Batch result")
    }

    func testBothEmptyResultsSkipInjection() async {
        // When both streaming and batch return empty, skip injection.
        let streaming = MockStreamingDictationProvider(stubbedText: "")
        let dictation = MockDictationProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "Empty results from both paths should skip injection")
    }

    func testBothWhitespaceOnlyResultsSkipInjection() async {
        // When both streaming and batch return whitespace-only, skip injection.
        let streaming = MockStreamingDictationProvider(stubbedText: "   \n  ")
        let dictation = MockDictationProvider(stubbedText: "  \t  ")
        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(
            injector.injectionCount, 0,
            "Whitespace-only results from both paths should skip injection")
    }

    // MARK: - Transcript buffer

    func testStreamingStoresTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingDictationProvider(stubbedText: "Streamed text")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "Streamed text")
    }

    func testBothEmptyResultsDoNotStoreInBuffer() async {
        // When both streaming and batch return empty, nothing stored.
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingDictationProvider(stubbedText: "")
        let dictation = MockDictationProvider(stubbedText: "")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Empty results from both paths should not be stored in buffer")
    }

    func testStreamingEmptyButBatchSuccessStoresInBuffer() async {
        // When streaming returns empty but batch returns text, store batch result.
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingDictationProvider(stubbedText: "")
        let dictation = MockDictationProvider(stubbedText: "Batch text")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "Batch text", "Batch result should be stored when streaming is empty")
    }

    func testStreamingFailureWithBatchFallbackStoresInBuffer() async {
        let buffer = TranscriptBuffer()
        let streaming = MockStreamingDictationProvider()
        streaming.stubbedFinishError = DictationError.networkError("fail")
        let dictation = MockDictationProvider(stubbedText: "Batch recovered")
        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            dictationProvider: dictation, streamingProvider: streaming,
            transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "Batch recovered",
            "Batch fallback result should be stored in buffer")
    }

    // MARK: - Injection failure in streaming mode

    func testStreamingInjectionFailureTransitionsToInjectionFailed() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingDictationProvider(stubbedText: "streamed text")

        let (pipeline, audio, _, _, _, _, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .injectionFailed,
            "Pipeline should transition to injectionFailed on injection error in streaming mode")
    }

    func testStreamingInjectionFailurePreservesTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let streaming = MockStreamingDictationProvider(stubbedText: "preserved streaming text")

        let (pipeline, audio, _, _, _, _, _) = makeStreamingPipeline(
            streamingProvider: streaming, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "preserved streaming text",
            "Transcript should remain in buffer after injection failure in streaming mode")
    }

    func testStreamingCycleWorksAfterInjectionFailureAndReset() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingDictationProvider(stubbedText: "first attempt")

        let (pipeline, _, _, _, _, _, _) = makeStreamingPipeline(
            audioProvider: audio, streamingProvider: streaming,
            textInjector: injector, coordinator: coordinator)

        // First cycle: injection fails.
        await pipeline.activate()
        let emitTask1 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask1.cancel()

        var state = await coordinator.state
        XCTAssertEqual(state, .injectionFailed)

        // Reset (simulates user dismissing no-target HUD).
        await coordinator.reset()
        state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: injection succeeds.
        injector.stubbedError = nil
        streaming.stubbedText = "second attempt"

        await pipeline.activate()
        let emitTask2 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask2.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "second attempt")
    }

    // MARK: - Fallback to batch when no PCM stream

    func testFallbackToBatchWhenNoPCMStream() async {
        // Use a MockAudioProvider WITHOUT enablePCMStream (nil pcmAudioStream).
        let audio = MockAudioProvider()
        // enablePCMStream defaults to false, so pcmAudioStream is nil.

        let streaming = MockStreamingDictationProvider(stubbedText: "Should not be used")
        let dictation = MockDictationProvider(stubbedText: "Batch text")

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator(),
            streamingProvider: streaming
        )

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(
            streaming.startCallCount, 0,
            "Streaming should not be used when audio provider has no pcmAudioStream")
        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be used as fallback")
    }

    func testFallbackToBatchWhenNoStreamingProvider() async {
        let audio = makeStreamingAudioProvider()
        let dictation = MockDictationProvider(stubbedText: "Batch only")

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: RecordingCoordinator()
                // No streamingProvider passed — defaults to nil.
        )

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(
            dictation.dictateCallCount, 1,
            "Batch dictation should be used when no streaming provider is configured")
    }

    // MARK: - Multiple consecutive streaming cycles

    func testMultipleConsecutiveStreamingCycles() async {
        let streaming = MockStreamingDictationProvider()
        let audio = makeStreamingAudioProvider()
        let coordinator = RecordingCoordinator()
        let injector = MockTextInjector()

        let batch = makeSlowBatchProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: batch,
            textInjector: injector,
            coordinator: coordinator,
            streamingProvider: streaming
        )

        // First cycle.
        streaming.stubbedText = "First"
        await pipeline.activate()
        let emitTask1 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask1.cancel()

        var state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertEqual(injector.lastInjectedText, "First")

        // Second cycle.
        streaming.stubbedText = "Second"
        await pipeline.activate()
        let emitTask2 = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask2.cancel()

        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 2)
        XCTAssertEqual(injector.lastInjectedText, "Second")

        XCTAssertEqual(streaming.startCallCount, 2)
        XCTAssertEqual(streaming.finishCallCount, 2)
    }

    // MARK: - Rapid streaming activate/cancel cycles

    func testRapidStreamingActivateCancelCycles() async {
        let audio = makeStreamingAudioProvider()
        let streaming = MockStreamingDictationProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: MockDictationProvider(),
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            streamingProvider: streaming
        )

        for _ in 0..<5 {
            await pipeline.activate()
            await pipeline.cancel()
            let state = await coordinator.state
            XCTAssertEqual(state, .idle)
        }

        // One final full cycle to confirm nothing is broken.
        streaming.stubbedText = "After rapid cycles"
        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    // MARK: - Streaming send error during forwarding

    func testStreamingSendErrorDoesNotCrash() async {
        let streaming = MockStreamingDictationProvider(stubbedText: "Partial result")
        // Fail on the second sendAudio call.
        streaming.stubbedSendError = DictationError.networkError("send failed")

        let (pipeline, audio, _, _, _, injector, coordinator) = makeStreamingPipeline(
            streamingProvider: streaming)

        await pipeline.activate()

        // Emit a chunk to trigger the send error.
        audio.emitPCMChunk(makeNonSilentPCMChunk())
        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.complete()

        // The pipeline should still complete (finishStreaming returns text).
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.lastInjectedText, "Partial result")
    }

    // MARK: - Language parameter

    func testStreamingPassesNilLanguage() async {
        let (pipeline, audio, _, _, streaming, _, _) = makeStreamingPipeline()

        await pipeline.activate()
        let emitTask = emitChunksInBackground(audio)
        await pipeline.complete()
        emitTask.cancel()

        XCTAssertEqual(streaming.receivedLanguages.count, 1)
        XCTAssertNil(streaming.receivedLanguages.first ?? "not nil")
    }
}
