import Foundation
import Testing

@testable import VoiceKit

@Suite("Pipeline integration with mocks")
struct PipelineIntegrationTests {

    @Test("Full mock pipeline: read context then inject")
    func mockPipelineFlow() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.Notes",
                appName: "Notes",
                windowTitle: "My Note",
                focusedFieldContent: "Dear team,",
                cursorPosition: 10
            )
        )
        let injector = MockTextInjector()
        let audioProvider = MockAudioProvider()

        // Simulate hotkey press: start recording + read context.
        try await audioProvider.startRecording()
        let context = await contextProvider.readContext()

        #expect(audioProvider.isRecording)
        #expect(context.bundleID == "com.apple.Notes")
        #expect(context.focusedFieldContent == "Dear team,")

        // Simulate hotkey release: stop recording + inject.
        let buffer = try await audioProvider.stopRecording()
        #expect(!audioProvider.isRecording)
        #expect(buffer.duration == 1.0)

        // Simulate STT result and inject.
        let transcribedText = "I wanted to follow up on our discussion."
        try await injector.inject(text: transcribedText, into: context)

        #expect(injector.injectionCount == 1)
        #expect(injector.lastInjectedText == transcribedText)
        #expect(injector.injections[0].context.windowTitle == "My Note")
    }

    @Test("Mock pipeline handles multiple recording cycles")
    func multipleCycles() async throws {
        let contextProvider = MockAppContextProvider()
        let injector = MockTextInjector()
        let audioProvider = MockAudioProvider()

        for i in 1...3 {
            try await audioProvider.startRecording()
            _ = await contextProvider.readContext()
            _ = try await audioProvider.stopRecording()
            try await injector.inject(text: "Text \(i)", into: .stub)
        }

        #expect(audioProvider.startCallCount == 3)
        #expect(audioProvider.stopCallCount == 3)
        #expect(contextProvider.readContextCallCount == 3)
        #expect(injector.injectionCount == 3)
    }

    @Test("Mock pipeline with browser context includes URL")
    func browserPipeline() async throws {
        let browserContext = AppContext(
            bundleID: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "GitHub",
            browserURL: "https://github.com",
            focusedFieldContent: "",
            cursorPosition: 0
        )
        let contextProvider = MockAppContextProvider(context: browserContext)
        let injector = MockTextInjector()

        let context = await contextProvider.readContext()
        #expect(context.browserURL == "https://github.com")

        try await injector.inject(text: "search query", into: context)
        #expect(injector.injections[0].context.browserURL == "https://github.com")
    }

    @Test("Context read and audio capture run concurrently")
    func concurrentContextAndAudio() async throws {
        let audioProvider = MockAudioProvider()
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.mail",
                appName: "Mail",
                windowTitle: "New Message",
                focusedFieldContent: "Dear ",
                cursorPosition: 5
            )
        )

        try await audioProvider.startRecording()

        async let contextRead = contextProvider.readContext()

        let context = await contextRead
        let buffer = try await audioProvider.stopRecording()

        #expect(context.bundleID == "com.apple.mail")
        #expect(buffer.duration > 0)
        #expect(audioProvider.startCallCount == 1)
        #expect(audioProvider.stopCallCount == 1)
        #expect(contextProvider.readContextCallCount == 1)
    }

    @Test("Pipeline handles context with no focused field")
    func pipelineNoFocusedField() async throws {
        let contextProvider = MockAppContextProvider(
            context: AppContext(
                bundleID: "com.apple.finder",
                appName: "Finder",
                windowTitle: "Documents"
            )
        )
        let injector = MockTextInjector()

        let context = await contextProvider.readContext()

        #expect(context.focusedFieldContent == nil)
        #expect(context.cursorPosition == nil)

        try await injector.inject(text: "some text", into: context)
        #expect(injector.injectionCount == 1)
    }

    @Test("Hotkey provider drives the full pipeline via press and release")
    func hotkeyDrivesPipeline() async throws {
        let hotkeyProvider = MockHotkeyProvider()
        let audioProvider = MockAudioProvider()
        let contextProvider = MockAppContextProvider()
        let injector = MockTextInjector()

        nonisolated(unsafe) var pipelineCompleted = false

        try hotkeyProvider.register { event in
            Task {
                switch event {
                case .pressed:
                    try await audioProvider.startRecording()
                    _ = await contextProvider.readContext()
                case .released:
                    _ = try await audioProvider.stopRecording()
                    try await injector.inject(text: "result", into: .stub)
                    pipelineCompleted = true
                }
            }
        }

        hotkeyProvider.simulatePress()
        try await Task.sleep(nanoseconds: 50_000_000)

        hotkeyProvider.simulateRelease()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(audioProvider.startCallCount == 1)
        #expect(audioProvider.stopCallCount == 1)
        #expect(injector.injectionCount == 1)
        #expect(pipelineCompleted)

        hotkeyProvider.unregister()
    }
}

@Suite("Timeout helper")
struct TimeoutHelperTests {

    @Test("Return value when operation completes in time")
    func completesInTime() async {
        let result = await withTimeout(seconds: 1.0) {
            return 42
        }
        #expect(result == 42)
    }

    @Test("Return nil when operation exceeds deadline")
    func exceedsDeadline() async {
        let result = await withTimeout(seconds: 0.01) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return 42
        }
        #expect(result == nil)
    }

    @Test("Return string value promptly")
    func returnsStringPromptly() async {
        let result = await withTimeout(seconds: 1.0) {
            return "hello"
        }
        #expect(result == "hello")
    }
}
