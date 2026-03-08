import XCTest

@testable import VoiceKit

final class DictationPipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        dictationProvider: MockDictationProvider = MockDictationProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer? = nil
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider, MockDictationProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            dictationProvider: dictationProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer
        )
        return (
            pipeline, audioProvider, contextProvider, dictationProvider, textInjector, coordinator
        )
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() async {
        let (pipeline, _, _, _, _, _) = makePipeline()
        let state = await pipeline.state
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Full cycle: activate → complete → idle

    func testFullCycleTransitionsToIdleAfterCompletion() async {
        let (pipeline, _, _, _, _, coordinator) = makePipeline()

        await pipeline.activate()
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        await pipeline.complete()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
    }

    func testFullCycleStartsAndStopsAudioCapture() async {
        let (pipeline, audio, _, _, _, _) = makePipeline()

        await pipeline.activate()
        // Audio setup now runs in a background task after activate() returns.
        // Wait briefly for the setup task to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        XCTAssertEqual(audio.startCallCount, 1)
        var recording = audio.isRecording
        XCTAssertTrue(recording)

        await pipeline.complete()
        XCTAssertEqual(audio.stopCallCount, 1)
        recording = audio.isRecording
        XCTAssertFalse(recording)
    }

    func testFullCycleReadsContext() async {
        let (pipeline, _, context, _, _, _) = makePipeline()

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(context.readContextCallCount, 1)
    }

    func testFullCycleInjectsText() async {
        let (pipeline, _, _, _, injector, _) = makePipeline()

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(injector.injectionCount, 1)
        XCTAssertNotNil(injector.lastInjectedText)
    }

    func testInjectedTextMatchesDictationOutput() async {
        let dictation = MockDictationProvider(stubbedText: "Hello from dictation")
        let (pipeline, _, _, _, injector, _) = makePipeline(dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(injector.lastInjectedText, "Hello from dictation")
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testDictationReceivesAudioData() async {
        // Build a non-silent WAV buffer so the silence gate does not reject it.
        var pcmData = Data(capacity: 64000)
        for i in 0..<32000 {
            let sample: Int16 = i % 2 == 0 ? 3000 : -3000
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let buffer = AudioBuffer(
            data: wavData,
            duration: 2.0,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )
        let audio = MockAudioProvider(stubbedBuffer: buffer)
        let dictation = MockDictationProvider()
        let (pipeline, _, _, _, injector, _) = makePipeline(
            audioProvider: audio, dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(dictation.lastReceivedAudio, buffer.data)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testInjectedContextMatchesStubbedContext() async {
        let stubbedContext = AppContext(
            bundleID: "com.example.myapp",
            appName: "MyApp",
            windowTitle: "Document 1"
        )
        let contextProvider = MockAppContextProvider(context: stubbedContext)
        let (pipeline, _, _, _, injector, _) = makePipeline(contextProvider: contextProvider)

        await pipeline.activate()
        await pipeline.complete()

        let injections = injector.injections
        XCTAssertEqual(injections.count, 1)
        XCTAssertEqual(injections.first?.context, stubbedContext)
    }

    func testDictationReceivesAppContext() async {
        let stubbedContext = AppContext(
            bundleID: "com.apple.mail",
            appName: "Mail",
            windowTitle: "New Message"
        )
        let contextProvider = MockAppContextProvider(context: stubbedContext)
        let dictation = MockDictationProvider()
        let (pipeline, _, _, _, _, _) = makePipeline(
            contextProvider: contextProvider, dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(dictation.lastReceivedContext, stubbedContext)
    }

    // MARK: - State transitions during full cycle

    func testStatePassesThroughAllPhases() async {
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, _, _) = makePipeline(coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                // After returning to idle (the second idle), break.
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        // Let the stream subscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.activate()
        await pipeline.complete()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        // Expected: idle (initial), recording, processing, injecting, idle
        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .idle])
    }

    // MARK: - Multiple cycles

    func testMultipleConsecutiveCycles() async {
        let (pipeline, audio, context, _, injector, coordinator) = makePipeline()

        for cycle in 1...3 {
            await pipeline.activate()
            var currentState = await coordinator.state
            XCTAssertEqual(currentState, .recording, "Cycle \(cycle) should be recording")

            await pipeline.complete()
            currentState = await coordinator.state
            XCTAssertEqual(currentState, .idle, "Cycle \(cycle) should return to idle")
        }

        XCTAssertEqual(audio.startCallCount, 3)
        XCTAssertEqual(audio.stopCallCount, 3)
        XCTAssertEqual(context.readContextCallCount, 3)
        XCTAssertEqual(injector.injectionCount, 3)
    }

    // MARK: - Cancellation

    func testCancelFromRecordingResetsToIdle() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        await pipeline.activate()
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        await pipeline.cancel()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertFalse(audio.isRecording)
    }

    func testCancelFromIdleRemainsIdle() async {
        let (pipeline, _, _, _, _, coordinator) = makePipeline()

        await pipeline.cancel()
        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
    }

    func testCycleWorksAfterCancel() async {
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        // Start and cancel.
        await pipeline.activate()
        await pipeline.cancel()
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)

        // Start a fresh cycle — should work normally.
        await pipeline.activate()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        await pipeline.complete()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
        // startCallCount may be 1 or 2 depending on whether the cancelled
        // activate() reached startRecording() before the task was cancelled.
        // The important invariant is that the second cycle started audio.
        XCTAssertGreaterThanOrEqual(audio.startCallCount, 1)
    }

    // MARK: - Edge cases: activate/complete out of order

    func testActivateWhileRecordingIsIgnored() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        await pipeline.activate()
        // Audio setup runs in a background task after activate() returns.
        // Wait briefly for the setup task to complete.
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)

        // Double activate should be ignored.
        await pipeline.activate()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .recording)
        XCTAssertEqual(audio.startCallCount, 1, "Should not start recording twice")
    }

    func testCompleteFromIdleIsIgnored() async {
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        // Complete without activate should be a no-op.
        await pipeline.complete()
        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(audio.stopCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testDoubleCompleteIsIgnored() async {
        let (pipeline, audio, _, _, injector, coordinator) = makePipeline()

        await pipeline.activate()
        await pipeline.complete()
        var currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(injector.injectionCount, 1)

        // Second complete should be a no-op.
        await pipeline.complete()
        currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        XCTAssertEqual(audio.stopCallCount, 1, "Should not stop recording twice")
        XCTAssertEqual(injector.injectionCount, 1, "Should not inject twice")
    }

    // MARK: - Context uses stub context

    func testDefaultStubContextUsesTextEdit() async {
        let (pipeline, _, _, _, injector, _) = makePipeline()

        await pipeline.activate()
        await pipeline.complete()

        let injections = injector.injections
        XCTAssertEqual(injections.count, 1)
        XCTAssertEqual(injections.first?.context.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(injections.first?.context.appName, "TextEdit")
    }

    // MARK: - Empty audio buffer

    func testEmptyAudioBufferSkipsDictationAndResetsToIdle() async {
        let audio = MockAudioProvider(stubbedBuffer: .empty)
        let dictation = MockDictationProvider()
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(
            audioProvider: audio, dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        // Empty audio should skip dictation entirely and not inject.
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    // MARK: - Hotkey-driven simulation

    func testHotkeyDrivenFullCycle() async {
        let hotkey = MockHotkeyProvider()
        let audio = MockAudioProvider()
        let context = MockAppContextProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let dictation = MockDictationProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            dictationProvider: dictation,
            textInjector: injector,
            coordinator: coordinator
        )

        // Simulate what the app layer does: wire hotkey to pipeline.
        let completedExpectation = XCTestExpectation(description: "Pipeline cycle completes")

        try! hotkey.register { event in
            Task {
                switch event {
                case .pressed:
                    await pipeline.activate()
                case .released:
                    await pipeline.complete()
                    completedExpectation.fulfill()
                }
            }
        }

        hotkey.simulatePress()
        // Give activate() time to run.
        try? await Task.sleep(nanoseconds: 100_000_000)

        hotkey.simulateRelease()

        await fulfillment(of: [completedExpectation], timeout: 5.0)

        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
        XCTAssertEqual(audio.startCallCount, 1)
        XCTAssertEqual(audio.stopCallCount, 1)
        XCTAssertEqual(context.readContextCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)

        hotkey.unregister()
        XCTAssertFalse(hotkey.isRegistered)
    }

    // MARK: - Rapid press/release cycles

    func testRapidActivateCancelCycles() async {
        let (pipeline, _, _, _, _, coordinator) = makePipeline()

        for _ in 0..<5 {
            await pipeline.activate()
            await pipeline.cancel()
            let currentState = await coordinator.state
            XCTAssertEqual(currentState, .idle)
        }

        // One final full cycle to confirm nothing is broken.
        await pipeline.activate()
        await pipeline.complete()
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

    // MARK: - TranscriptBuffer wiring

    func testSuccessfulCycleStoresTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockDictationProvider(stubbedText: "Hello from buffer")
        let (pipeline, _, _, _, _, _) = makePipeline(
            dictationProvider: dictation, transcriptBuffer: buffer)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "Hello from buffer")
    }

    func testTranscriptBufferUpdatedOnEachCycle() async {
        let buffer = TranscriptBuffer()
        let dictation = MockDictationProvider(stubbedText: "first")
        let (pipeline, _, _, _, _, _) = makePipeline(
            dictationProvider: dictation, transcriptBuffer: buffer)

        await pipeline.activate()
        await pipeline.complete()
        var stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "first")

        dictation.stubbedText = "second"
        await pipeline.activate()
        await pipeline.complete()
        stored = await buffer.lastTranscript
        XCTAssertEqual(stored, "second")
    }

    func testEmptyDictationResultDoesNotStoreInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockDictationProvider(stubbedText: "   ")
        let (pipeline, _, _, _, _, _) = makePipeline(
            dictationProvider: dictation, transcriptBuffer: buffer)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Empty dictation result should not be stored in buffer")
    }

    func testDictationFailureDoesNotStoreInBuffer() async {
        let buffer = TranscriptBuffer()
        let dictation = MockDictationProvider()
        dictation.stubbedError = DictationError.requestFailed(statusCode: 500, message: "fail")
        let (pipeline, _, _, _, _, _) = makePipeline(
            dictationProvider: dictation, transcriptBuffer: buffer)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertNil(stored, "Dictation failure should not store anything in buffer")
    }

    func testPipelineWorksWithoutTranscriptBuffer() async {
        // Passing nil (the default) should not change existing behavior.
        let (pipeline, _, _, _, injector, coordinator) = makePipeline()

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    // MARK: - Injection failure → injectionFailed

    func testInjectionFailureTransitionsToInjectionFailed() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let dictation = MockDictationProvider(stubbedText: "dictated text")
        let (pipeline, _, _, _, _, coordinator) = makePipeline(
            dictationProvider: dictation, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(
            state, .injectionFailed,
            "Pipeline should transition to injectionFailed when injection throws")
    }

    func testInjectionFailurePreservesTranscriptInBuffer() async {
        let buffer = TranscriptBuffer()
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let dictation = MockDictationProvider(stubbedText: "preserved text")
        let (pipeline, _, _, _, _, _) = makePipeline(
            dictationProvider: dictation, textInjector: injector, transcriptBuffer: buffer)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.lastTranscript
        XCTAssertEqual(
            stored, "preserved text",
            "Transcript should remain in buffer after injection failure")
    }

    func testInjectionFailureStatePassesThroughAllPhases() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, _, _) = makePipeline(
            textInjector: injector, coordinator: coordinator)

        var collected: [RecordingState] = []
        let expectation = XCTestExpectation(description: "Collect all state transitions")

        let streamTask = Task {
            for await state in await coordinator.stateStream {
                collected.append(state)
                if collected.count >= 5 {
                    break
                }
            }
            expectation.fulfill()
        }

        try? await Task.sleep(nanoseconds: 50_000_000)

        await pipeline.activate()
        await pipeline.complete()

        await fulfillment(of: [expectation], timeout: 5.0)
        streamTask.cancel()

        // Expected: idle (initial), recording, processing, injecting, injectionFailed
        XCTAssertEqual(collected, [.idle, .recording, .processing, .injecting, .injectionFailed])
    }

    func testCycleWorksAfterInjectionFailureAndReset() async {
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let coordinator = RecordingCoordinator()
        let (pipeline, _, _, _, _, _) = makePipeline(
            textInjector: injector, coordinator: coordinator)

        // First cycle: injection fails.
        await pipeline.activate()
        await pipeline.complete()
        var state = await coordinator.state
        XCTAssertEqual(state, .injectionFailed)

        // Reset (simulates user dismissing no-target HUD).
        await coordinator.reset()
        state = await coordinator.state
        XCTAssertEqual(state, .idle)

        // Second cycle: injection succeeds.
        injector.stubbedError = nil
        await pipeline.activate()
        await pipeline.complete()
        state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    // MARK: - Silence gate

    func testSilentAudioSkipsDictationAndResetsToIdle() async {
        // Build a WAV buffer with all-zero (silent) samples.
        let silentPCM = Data(repeating: 0, count: 32000)
        let silentWAV = WAVEncoder.encode(
            pcmData: silentPCM, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let silentBuffer = AudioBuffer(
            data: silentWAV,
            duration: 1.0,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: silentBuffer)
        let dictation = MockDictationProvider()
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(
            audioProvider: audio, dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Silent audio should skip dictation entirely.
        XCTAssertEqual(dictation.dictateCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    func testNonSilentAudioProceedsToDictation() async {
        // The default MockAudioProvider now produces non-silent audio.
        let dictation = MockDictationProvider(stubbedText: "Hello")
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(
            dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
        XCTAssertEqual(injector.injectionCount, 1)
    }

    func testCustomSilenceThresholdRejectsQuietAudio() async {
        // Build a buffer with low-amplitude samples (±100 → RMS ≈ 0.003).
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 100 : -100
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.1,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        let dictation = MockDictationProvider()
        let coordinator = RecordingCoordinator()

        // Use a high threshold so the quiet audio is rejected.
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.01
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testCustomSilenceThresholdAllowsQuietAudio() async {
        // Same quiet buffer as above, but with a very low threshold.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 100 : -100
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.1,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        let dictation = MockDictationProvider(stubbedText: "whisper")
        let coordinator = RecordingCoordinator()

        // Use a very low threshold so the quiet audio passes through.
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.001
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    // MARK: - Adaptive silence threshold

    func testAdaptiveThresholdAllowsQuietBuiltInMicSpeech() async {
        // Built-in MacBook mic: ambient ~0.001, quiet speech peaks at
        // 0.004. The fixed threshold (0.005) would reject this, but the
        // adaptive threshold (0.001 * 2.0 = 0.002) lets it through.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 130 : -130
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.6,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        // peakRMS 0.004 is above adaptive threshold 0.002 but below
        // fixed threshold 0.005.
        audio.stubbedPeakRMS = 0.004
        audio.stubbedAmbientRMS = 0.001

        let dictation = MockDictationProvider(stubbedText: "quiet speech")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // The adaptive threshold (0.002) lets the audio through.
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }

    func testAdaptiveThresholdRejectsAirPodsAmbientNoise() async {
        // AirPods: ambient ~0.002, noise floor peaks at 0.003.
        // Adaptive threshold = 0.002 * 2.0 = 0.004, rejects the noise.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 130 : -130
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let noiseBuffer = AudioBuffer(
            data: wavData,
            duration: 0.6,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: noiseBuffer)
        audio.stubbedPeakRMS = 0.003
        audio.stubbedAmbientRMS = 0.002

        let dictation = MockDictationProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Adaptive threshold (0.004) rejects the 0.003 peak.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testFallsBackToFixedThresholdWhenNoAmbientCalibration() async {
        // When ambientRMS is 0 (calibration not completed), the pipeline
        // falls back to the fixed silenceThreshold.
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 100 : -100
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let quietBuffer = AudioBuffer(
            data: wavData,
            duration: 0.1,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: quietBuffer)
        audio.stubbedPeakRMS = 0.003
        audio.stubbedAmbientRMS = 0  // No calibration

        let dictation = MockDictationProvider()
        let coordinator = RecordingCoordinator()

        // Fixed threshold 0.005 rejects peakRMS 0.003.
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testAdaptiveThresholdFloorPreventsZeroThreshold() async {
        // Even with very low ambient noise, the threshold should not
        // drop below the minimum floor (0.0005).
        var pcmData = Data(capacity: 3200)
        for i in 0..<1600 {
            let sample: Int16 = i % 2 == 0 ? 3 : -3
            withUnsafeBytes(of: sample.littleEndian) { pcmData.append(contentsOf: $0) }
        }
        let wavData = WAVEncoder.encode(
            pcmData: pcmData, sampleRate: 16000, channels: 1, bitsPerSample: 16)
        let nearSilentBuffer = AudioBuffer(
            data: wavData,
            duration: 0.6,
            sampleRate: 16000,
            channels: 1,
            bitsPerSample: 16
        )

        let audio = MockAudioProvider(stubbedBuffer: nearSilentBuffer)
        // Ambient 0.0001 * 2.0 = 0.0002, below the floor of 0.0005.
        // Effective threshold should be 0.0005, rejecting peakRMS 0.0003.
        audio.stubbedPeakRMS = 0.0003
        audio.stubbedAmbientRMS = 0.0001

        let dictation = MockDictationProvider()
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // Floor threshold (0.0005) rejects the 0.0003 peak.
        XCTAssertEqual(dictation.dictateCallCount, 0)
    }

    func testAdaptiveThresholdLetsSpeechThroughWithHighAmbient() async {
        // Coffee shop: ambient ~0.003, speech peaks at 0.015.
        // Adaptive threshold = 0.003 * 2.0 = 0.006, speech clears it.
        let audio = MockAudioProvider()
        audio.stubbedPeakRMS = 0.015
        audio.stubbedAmbientRMS = 0.003

        let dictation = MockDictationProvider(stubbedText: "coffee shop speech")
        let coordinator = RecordingCoordinator()

        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: MockAppContextProvider(),
            dictationProvider: dictation,
            textInjector: MockTextInjector(),
            coordinator: coordinator,
            silenceThreshold: 0.005
        )

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(dictation.dictateCallCount, 1)
    }
}
