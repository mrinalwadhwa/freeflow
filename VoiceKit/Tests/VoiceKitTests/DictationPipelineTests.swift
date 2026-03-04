import XCTest

@testable import VoiceKit

final class DictationPipelineTests: XCTestCase {

    // MARK: - Helpers

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        sttProvider: MockSTTProvider = MockSTTProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator()
    ) -> (
        DictationPipeline, MockAudioProvider, MockAppContextProvider, MockSTTProvider,
        MockTextInjector, RecordingCoordinator
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            sttProvider: sttProvider,
            textInjector: textInjector,
            coordinator: coordinator
        )
        return (pipeline, audioProvider, contextProvider, sttProvider, textInjector, coordinator)
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

    func testInjectedTextMatchesMockSTTOutput() async {
        let stt = MockSTTProvider(stubbedText: "Hello from STT")
        let (pipeline, _, _, _, injector, _) = makePipeline(sttProvider: stt)

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(injector.lastInjectedText, "Hello from STT")
        XCTAssertEqual(stt.transcribeCallCount, 1)
    }

    func testSTTReceivesAudioData() async {
        let buffer = AudioBuffer(
            data: Data(repeating: 0, count: 64000),
            duration: 2.0
        )
        let audio = MockAudioProvider(stubbedBuffer: buffer)
        let stt = MockSTTProvider()
        let (pipeline, _, _, _, injector, _) = makePipeline(audioProvider: audio, sttProvider: stt)

        await pipeline.activate()
        await pipeline.complete()

        XCTAssertEqual(stt.transcribeCallCount, 1)
        XCTAssertEqual(stt.lastReceivedAudio, buffer.data)
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
        XCTAssertEqual(audio.startCallCount, 2)
    }

    // MARK: - Edge cases: activate/complete out of order

    func testActivateWhileRecordingIsIgnored() async {
        let (pipeline, audio, _, _, _, coordinator) = makePipeline()

        await pipeline.activate()
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

    func testEmptyAudioBufferSkipsSTTAndResetsToIdle() async {
        let audio = MockAudioProvider(stubbedBuffer: .empty)
        let stt = MockSTTProvider()
        let (pipeline, _, _, _, injector, coordinator) = makePipeline(
            audioProvider: audio, sttProvider: stt)

        await pipeline.activate()
        await pipeline.complete()

        let currentState = await coordinator.state
        XCTAssertEqual(currentState, .idle)
        // Empty audio should skip STT entirely and not inject.
        XCTAssertEqual(stt.transcribeCallCount, 0)
        XCTAssertEqual(injector.injectionCount, 0)
    }

    // MARK: - Hotkey-driven simulation

    func testHotkeyDrivenFullCycle() async {
        let hotkey = MockHotkeyProvider()
        let audio = MockAudioProvider()
        let context = MockAppContextProvider()
        let injector = MockTextInjector()
        let coordinator = RecordingCoordinator()
        let stt = MockSTTProvider()
        let pipeline = DictationPipeline(
            audioProvider: audio,
            contextProvider: context,
            sttProvider: stt,
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
}
