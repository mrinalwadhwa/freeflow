import Foundation
import Testing

@testable import VoiceKit

@Suite("TranscriptBuffer")
struct TranscriptBufferTests {

    @Test("Empty buffer has no transcript")
    func emptyBuffer() async {
        let buffer = TranscriptBuffer()

        #expect(await buffer.lastTranscript == nil)
        #expect(await buffer.timestamp == nil)
        #expect(await buffer.hasTranscript == false)
    }

    @Test("Store makes transcript available")
    func storeTranscript() async {
        let buffer = TranscriptBuffer()

        await buffer.store("Hello world")

        #expect(await buffer.lastTranscript == "Hello world")
        #expect(await buffer.hasTranscript == true)
        #expect(await buffer.timestamp != nil)
    }

    @Test("Store sets timestamp close to now")
    func storeTimestamp() async {
        let buffer = TranscriptBuffer()
        let before = Date()

        await buffer.store("Test")

        let timestamp = await buffer.timestamp
        #expect(timestamp != nil)
        #expect(timestamp! >= before)
        #expect(timestamp!.timeIntervalSince(before) < 1.0)
    }

    @Test("Consume returns and clears the transcript")
    func consumeTranscript() async {
        let buffer = TranscriptBuffer()
        await buffer.store("Dictated text")

        let result = await buffer.consume()

        #expect(result == "Dictated text")
        #expect(await buffer.lastTranscript == nil)
        #expect(await buffer.timestamp == nil)
        #expect(await buffer.hasTranscript == false)
    }

    @Test("Consume on empty buffer returns nil")
    func consumeEmpty() async {
        let buffer = TranscriptBuffer()

        let result = await buffer.consume()

        #expect(result == nil)
    }

    @Test("Double consume returns nil on second call")
    func doubleConsume() async {
        let buffer = TranscriptBuffer()
        await buffer.store("Once only")

        let first = await buffer.consume()
        let second = await buffer.consume()

        #expect(first == "Once only")
        #expect(second == nil)
    }

    @Test("Clear removes stored transcript")
    func clearTranscript() async {
        let buffer = TranscriptBuffer()
        await buffer.store("To be cleared")

        await buffer.clear()

        #expect(await buffer.lastTranscript == nil)
        #expect(await buffer.timestamp == nil)
        #expect(await buffer.hasTranscript == false)
    }

    @Test("Clear on empty buffer is safe")
    func clearEmpty() async {
        let buffer = TranscriptBuffer()

        await buffer.clear()

        #expect(await buffer.hasTranscript == false)
    }

    @Test("Store replaces previous transcript")
    func storeReplaces() async {
        let buffer = TranscriptBuffer()

        await buffer.store("First")
        await buffer.store("Second")

        #expect(await buffer.lastTranscript == "Second")
        #expect(await buffer.hasTranscript == true)
    }

    @Test("Store after consume makes new transcript available")
    func storeAfterConsume() async {
        let buffer = TranscriptBuffer()

        await buffer.store("First")
        let consumed = await buffer.consume()
        #expect(consumed == "First")

        await buffer.store("Second")
        #expect(await buffer.lastTranscript == "Second")
        #expect(await buffer.hasTranscript == true)
    }

    @Test("Store after clear makes new transcript available")
    func storeAfterClear() async {
        let buffer = TranscriptBuffer()

        await buffer.store("Before clear")
        await buffer.clear()
        await buffer.store("After clear")

        #expect(await buffer.lastTranscript == "After clear")
    }

    @Test("Store updates timestamp on replace")
    func storeUpdatesTimestamp() async {
        let buffer = TranscriptBuffer()

        await buffer.store("First")
        let firstTimestamp = await buffer.timestamp

        // Small delay to ensure timestamps differ
        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

        await buffer.store("Second")
        let secondTimestamp = await buffer.timestamp

        #expect(firstTimestamp != nil)
        #expect(secondTimestamp != nil)
        #expect(secondTimestamp! >= firstTimestamp!)
    }
}
