import Foundation
import Testing

@testable import FreeFlowKit

@Suite("MockDictationProvider")
struct MockDictationProviderTests {

    @Test("Default returns stubbed text")
    func defaultReturnsStubbedText() async throws {
        let provider = MockDictationProvider(stubbedText: "hello world")
        let result = try await provider.dictate(
            audio: Data([0x01, 0x02]),
            context: .empty
        )
        #expect(result == "hello world")
        #expect(provider.dictateCallCount == 1)
    }

    @Test("Stubbed error is thrown")
    func stubbedErrorThrown() async {
        let provider = MockDictationProvider()
        provider.stubbedError = DictationError.requestFailed(
            statusCode: 502, message: "bad gateway")

        do {
            _ = try await provider.dictate(audio: Data([0x01]), context: .empty)
            Issue.record("Expected error to be thrown")
        } catch {
            #expect(error is DictationError)
        }
        #expect(provider.dictateCallCount == 1)
    }

    @Test("Records received audio and contexts")
    func recordsArguments() async throws {
        let provider = MockDictationProvider()
        let context = AppContext(
            bundleID: "com.apple.mail",
            appName: "Mail",
            windowTitle: "New Message"
        )

        let audio1 = Data([0x01, 0x02])
        let audio2 = Data([0x03, 0x04])
        _ = try await provider.dictate(audio: audio1, context: .empty)
        _ = try await provider.dictate(audio: audio2, context: context)

        #expect(provider.dictateCallCount == 2)
        #expect(provider.receivedAudioData == [audio1, audio2])
        #expect(provider.lastReceivedAudio == audio2)
        #expect(provider.lastReceivedContext == context)
    }

    @Test("Reset clears all recorded state")
    func resetClearsState() async throws {
        let provider = MockDictationProvider()
        _ = try await provider.dictate(audio: Data([0x01]), context: .empty)
        #expect(provider.dictateCallCount == 1)

        provider.reset()
        #expect(provider.dictateCallCount == 0)
        #expect(provider.receivedAudioData.isEmpty)
        #expect(provider.receivedContexts.isEmpty)
        #expect(provider.lastReceivedAudio == nil)
        #expect(provider.lastReceivedContext == nil)
    }

    @Test("Changing stubbedText between calls returns different results")
    func changingStubbedText() async throws {
        let provider = MockDictationProvider(stubbedText: "first")
        var result = try await provider.dictate(audio: Data([0x01]), context: .empty)
        #expect(result == "first")

        provider.stubbedText = "second"
        result = try await provider.dictate(audio: Data([0x02]), context: .empty)
        #expect(result == "second")
        #expect(provider.dictateCallCount == 2)
    }
}

@Suite("Pipeline dictation")
struct PipelineDictationTests {

    private func makePipeline(
        audioProvider: MockAudioProvider = MockAudioProvider(),
        contextProvider: MockAppContextProvider = MockAppContextProvider(),
        dictationProvider: MockDictationProvider = MockDictationProvider(),
        textInjector: MockTextInjector = MockTextInjector(),
        coordinator: RecordingCoordinator = RecordingCoordinator(),
        transcriptBuffer: TranscriptBuffer = TranscriptBuffer()
    ) -> (
        DictationPipeline, MockDictationProvider, MockTextInjector,
        RecordingCoordinator, TranscriptBuffer
    ) {
        let pipeline = DictationPipeline(
            audioProvider: audioProvider,
            contextProvider: contextProvider,
            dictationProvider: dictationProvider,
            textInjector: textInjector,
            coordinator: coordinator,
            transcriptBuffer: transcriptBuffer
        )
        return (pipeline, dictationProvider, textInjector, coordinator, transcriptBuffer)
    }

    @Test("Pipeline injects dictated text")
    func injectsDictatedText() async {
        let dictation = MockDictationProvider(
            stubbedText: "I think we should meet tomorrow.")
        let (pipeline, _, injector, coordinator, _) = makePipeline(
            dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
        #expect(injector.lastInjectedText == "I think we should meet tomorrow.")
    }

    @Test("Buffer stores dictated text")
    func bufferStoresDictatedText() async {
        let dictation = MockDictationProvider(stubbedText: "Stored text.")
        let (pipeline, _, _, _, buffer) = makePipeline(dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let stored = await buffer.consume()
        #expect(stored == "Stored text.")
    }

    @Test("Empty text skips injection")
    func emptyTextSkipsInjection() async {
        let dictation = MockDictationProvider(stubbedText: "   ")
        let (pipeline, _, injector, coordinator, _) = makePipeline(
            dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
        #expect(injector.injectionCount == 0)
    }

    @Test("Dictation failure resets to idle without injecting")
    func dictationFailureResetsToIdle() async {
        let dictation = MockDictationProvider()
        dictation.stubbedError = DictationError.networkError("connection refused")
        let (pipeline, _, injector, coordinator, buffer) = makePipeline(
            dictationProvider: dictation)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .idle)
        #expect(injector.injectionCount == 0)
        let stored = await buffer.lastTranscript
        #expect(stored == nil)
    }

    @Test("Injection failure stores text for recovery")
    func injectionFailureStoresText() async {
        let dictation = MockDictationProvider(stubbedText: "Test.")
        let injector = MockTextInjector()
        injector.stubbedError = AppTextInjector.InjectionError.noFocusedElement
        let (pipeline, _, _, coordinator, buffer) = makePipeline(
            dictationProvider: dictation, textInjector: injector)

        await pipeline.activate()
        await pipeline.complete()

        let state = await coordinator.state
        #expect(state == .injectionFailed)
        let stored = await buffer.consume()
        #expect(stored == "Test.")
    }
}
