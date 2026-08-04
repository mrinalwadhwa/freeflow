import AVFoundation
import Foundation
import Testing

@testable import UnrambleKit

@Suite("Far-end playback")
struct FarEndPlaybackTests {

    // MARK: - Ring

    @Test("Frames round-trip in order across the wrap point")
    func ringRoundTripsAcrossWrap() {
        let ring = FarEndAudioRing(capacity: 8)
        var output = [Float](repeating: 0, count: 8)

        #expect(ring.write([1, 2, 3, 4, 5, 6], from: 0) == 6)
        output.withUnsafeMutableBufferPointer { buffer in
            #expect(ring.read(into: buffer.baseAddress!, count: 4) == 4)
        }
        #expect(Array(output[0..<4]) == [1, 2, 3, 4])

        // Wraps around the storage boundary.
        #expect(ring.write([7, 8, 9, 10], from: 0) == 4)
        output.withUnsafeMutableBufferPointer { buffer in
            #expect(ring.read(into: buffer.baseAddress!, count: 6) == 6)
        }
        #expect(Array(output[0..<6]) == [5, 6, 7, 8, 9, 10])
    }

    @Test("A full ring accepts only what fits")
    func ringLimitsWrites() {
        let ring = FarEndAudioRing(capacity: 4)
        #expect(ring.write([1, 2, 3, 4, 5, 6], from: 0) == 4)
        #expect(ring.write([5], from: 0) == 0)
        #expect(ring.framesBuffered == 4)
    }

    @Test("Clear advances consumption to the write position")
    func ringClearAdvancesConsumption() {
        let ring = FarEndAudioRing(capacity: 8)
        _ = ring.write([1, 2, 3], from: 0)
        ring.clear()
        #expect(ring.framesBuffered == 0)
        #expect(ring.framesConsumed == 3)
    }

    // MARK: - Render fill

    @Test("The render fill drains the ring and zero-fills the rest")
    func renderFillDrainsAndZeroFills() throws {
        let ring = FarEndAudioRing(capacity: 16)
        _ = ring.write([0.5, 0.25], from: 0)
        let state = FarEndRenderState(ring: ring)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        buffer.floatChannelData![0].update(repeating: 9, count: 4)

        var flags = AudioUnitRenderActionFlags()
        let status = withUnsafeMutablePointer(to: &flags) { flagsPointer in
            state.fill(
                ioData: buffer.mutableAudioBufferList,
                actionFlags: flagsPointer)
        }

        #expect(status == noErr)
        let rendered = Array(
            UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: 4))
        #expect(rendered == [0.5, 0.25, 0, 0])
        #expect(!flags.contains(.unitRenderAction_OutputIsSilence))
    }

    @Test("An empty ring renders flagged silence")
    func renderFillFlagsSilence() throws {
        let state = FarEndRenderState(ring: FarEndAudioRing(capacity: 4))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        buffer.floatChannelData![0].update(repeating: 9, count: 4)

        var flags = AudioUnitRenderActionFlags()
        _ = withUnsafeMutablePointer(to: &flags) { flagsPointer in
            state.fill(
                ioData: buffer.mutableAudioBufferList,
                actionFlags: flagsPointer)
        }

        let rendered = Array(
            UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: 4))
        #expect(rendered == [0, 0, 0, 0])
        #expect(flags.contains(.unitRenderAction_OutputIsSilence))
    }

    // MARK: - Player

    private func makeChannel(
        capacity: Int = 48_000,
        sampleRate: Double = 48_000,
        active: Bool = true
    ) -> FarEndPlaybackChannel {
        let channel = FarEndPlaybackChannel(
            ring: FarEndAudioRing(capacity: capacity),
            sampleRate: sampleRate)
        channel.setActive(active)
        return channel
    }

    private func buffer(
        _ samples: [Float],
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0]
                .update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    @Test("A chunk completes once the ring consumes past its end")
    func playerCompletesOnConsumption() async {
        let channel = makeChannel()
        let player = FarEndPCMChunkPlayer(
            inputSampleRate: 48_000, channel: channel)
        let completed = CompletionFlag()

        player.schedule(
            buffer: buffer([0.1, 0.2, 0.3], format: player.format!)
        ) { completed.raise() }

        // The pump fills the ring; nothing completes until the
        // render side consumes it.
        await eventually { channel.ring.framesBuffered == 3 }
        #expect(!completed.isRaised)

        var drainTarget = [Float](repeating: 0, count: 3)
        drainTarget.withUnsafeMutableBufferPointer { target in
            _ = channel.ring.read(into: target.baseAddress!, count: 3)
        }
        await eventually { completed.isRaised }
        #expect(completed.isRaised)
    }

    @Test("A 24 kHz chunk is resampled to the channel rate")
    func playerResamplesToChannelRate() async {
        let channel = makeChannel(sampleRate: 48_000)
        let player = FarEndPCMChunkPlayer(
            inputSampleRate: 24_000, channel: channel)
        let completed = CompletionFlag()

        let samples = [Float](repeating: 0.5, count: 240)
        player.schedule(
            buffer: buffer(samples, format: player.format!)
        ) { completed.raise() }

        // Doubling the rate roughly doubles the frames; converters
        // may hold a few frames of priming latency.
        await eventually { channel.ring.framesBuffered >= 400 }
        #expect(channel.ring.framesBuffered >= 400)
        #expect(channel.ring.framesBuffered <= 560)
    }

    @Test("An inactive channel resolves completions instead of waiting")
    func inactiveChannelResolvesCompletions() async {
        let channel = makeChannel(active: false)
        let player = FarEndPCMChunkPlayer(
            inputSampleRate: 48_000, channel: channel)
        let completed = CompletionFlag()

        player.schedule(
            buffer: buffer([0.1, 0.2], format: player.format!)
        ) { completed.raise() }

        await eventually { completed.isRaised }
        #expect(completed.isRaised)
    }

    @Test("Stop clears the ring and rejects later chunks")
    func stopClearsAndRejects() async {
        let channel = makeChannel()
        let player = FarEndPCMChunkPlayer(
            inputSampleRate: 48_000, channel: channel)
        player.schedule(
            buffer: buffer([0.1, 0.2, 0.3], format: player.format!)
        ) {}
        await eventually { channel.ring.framesBuffered == 3 }

        player.stop()
        #expect(channel.ring.framesBuffered == 0)

        let rejected = CompletionFlag()
        player.schedule(
            buffer: buffer([0.4], format: player.format!)
        ) { rejected.raise() }
        #expect(rejected.isRaised)
    }

    // MARK: - Routing

    @Test("Playback routes far-end only while a channel is active")
    func playbackRoutesByChannelState() {
        let hub = FarEndPlaybackHub()
        let engineRouted = PCMChunkPlayback(
            sampleRate: 24_000, farEndHub: hub)
        #expect(!(engineRouted.player is FarEndPCMChunkPlayer))

        let channel = makeChannel()
        hub.activate(channel)
        let farEndRouted = PCMChunkPlayback(
            sampleRate: 24_000, farEndHub: hub)
        #expect(farEndRouted.player is FarEndPCMChunkPlayer)

        hub.deactivate(channel)
        let backToEngine = PCMChunkPlayback(
            sampleRate: 24_000, farEndHub: hub)
        #expect(!(backToEngine.player is FarEndPCMChunkPlayer))
    }

    // MARK: - Helpers

    private final class CompletionFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }

    @discardableResult
    private func eventually(
        _ condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
