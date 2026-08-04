import AVFoundation
import Foundation

/// Bridge synthesized speech into the voice processing unit's output
/// bus — the echo canceller's far-end reference.
///
/// Playback the canceller only observes as "other audio" is
/// suppressed enough for ears but not for a recognizer: the residual
/// is still faint speech, which live testing showed barging its own
/// narration and transcribing into hallucinated turns. Audio rendered
/// through the unit's own output bus is the canceller's true
/// reference, and its cancellation is near-total. While a
/// voice-processed capture runs, its transport activates a channel
/// here; speech playback then routes through the channel instead of a
/// separate engine.

/// A bounded ring of mono float frames between one producer (the
/// playback pump) and one consumer (the audio render callback). The
/// counters are absolute and monotonic so a chunk's completion can be
/// expressed as "consumed passed this frame".
final class FarEndAudioRing: @unchecked Sendable {

    private let capacity: Int
    private var storage: [Float]
    private let lock = NSLock()
    private var readCount = 0
    private var writeCount = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = [Float](repeating: 0, count: self.capacity)
    }

    /// Total frames the consumer has taken since creation. A `clear`
    /// advances this to the write position, so completions keyed on
    /// it resolve rather than wait forever.
    var framesConsumed: Int { lock.withLock { readCount } }

    /// Total frames the producer has written since creation.
    var framesWritten: Int { lock.withLock { writeCount } }

    var framesBuffered: Int { lock.withLock { writeCount - readCount } }

    /// Append as many frames as fit; return how many were accepted.
    func write(_ samples: [Float], from offset: Int) -> Int {
        lock.withLock {
            let free = capacity - (writeCount - readCount)
            let count = min(free, samples.count - offset)
            guard count > 0 else { return 0 }
            storage.withUnsafeMutableBufferPointer { buffer in
                for index in 0..<count {
                    buffer[(writeCount + index) % capacity] =
                        samples[offset + index]
                }
            }
            writeCount += count
            return count
        }
    }

    /// Move up to `count` buffered frames into `destination`; return
    /// how many were delivered.
    func read(into destination: UnsafeMutablePointer<Float>, count: Int)
        -> Int
    {
        lock.withLock {
            let available = min(count, writeCount - readCount)
            guard available > 0 else { return 0 }
            storage.withUnsafeBufferPointer { buffer in
                for index in 0..<available {
                    destination[index] = buffer[(readCount + index) % capacity]
                }
            }
            readCount += available
            return available
        }
    }

    /// Drop everything buffered. Consumption jumps to the write
    /// position, so pending completions resolve as played.
    func clear() {
        lock.withLock { readCount = writeCount }
    }
}

/// One capture transport's far-end playback address: its ring and the
/// rate the render callback consumes at.
public final class FarEndPlaybackChannel: @unchecked Sendable {

    let ring: FarEndAudioRing
    public let sampleRate: Double

    private let lock = NSLock()
    private var active = false

    init(ring: FarEndAudioRing, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
    }

    /// Whether the owning transport is currently rendering. An
    /// inactive channel consumes nothing; playback routed to it must
    /// resolve instead of waiting on a silent bus.
    public var isActive: Bool { lock.withLock { active } }

    func setActive(_ value: Bool) {
        lock.withLock { active = value }
    }
}

/// The rendezvous between the capture transport and speech playback.
/// The transport activates its channel while it renders; playback
/// consults the hub per utterance.
public final class FarEndPlaybackHub: @unchecked Sendable {

    private let lock = NSLock()
    private var current: FarEndPlaybackChannel?

    public init() {}

    public var activeChannel: FarEndPlaybackChannel? {
        lock.withLock { current }
    }

    /// Wait briefly for a channel to come up. Capture activation can
    /// resolve before its transport physically starts rendering, and
    /// a narration that races ahead of the channel falls back to an
    /// engine the canceller only hears as other audio.
    public func waitForActiveChannel(
        timeoutSeconds: Double
    ) async -> FarEndPlaybackChannel? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let channel = activeChannel { return channel }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return activeChannel
    }

    func activate(_ channel: FarEndPlaybackChannel) {
        lock.withLock {
            current?.setActive(false)
            channel.setActive(true)
            current = channel
        }
    }

    func deactivate(_ channel: FarEndPlaybackChannel) {
        lock.withLock {
            guard current === channel else { return }
            channel.setActive(false)
            channel.ring.clear()
            current = nil
        }
    }
}

/// Fill the unit's output bus from the ring, zero-filling whatever
/// the ring cannot cover. Separated from the C callback so the fill
/// logic is testable.
final class FarEndRenderState: @unchecked Sendable {

    private let ring: FarEndAudioRing?

    init(ring: FarEndAudioRing?) {
        self.ring = ring
    }

    func fill(
        ioData: UnsafeMutablePointer<AudioBufferList>?,
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>
    ) -> OSStatus {
        var produced = 0
        if let ioData {
            var first = true
            for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
                guard let data = buffer.mData else { continue }
                let byteCount = Int(buffer.mDataByteSize)
                if first, let ring {
                    first = false
                    let frames = byteCount / MemoryLayout<Float>.size
                    let floats = data.assumingMemoryBound(to: Float.self)
                    produced = ring.read(into: floats, count: frames)
                    if produced < frames {
                        (floats + produced).update(
                            repeating: 0, count: frames - produced)
                    }
                } else {
                    memset(data, 0, byteCount)
                }
            }
        }
        if produced == 0 {
            actionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        }
        return noErr
    }
}

/// Play PCM chunks through a far-end channel. Chunks queue without
/// bound off the audio path; a pump feeds the ring as the render
/// callback frees space and fires each chunk's completion once
/// consumption passes its final frame.
final class FarEndPCMChunkPlayer: PCMChunkPlaying, @unchecked Sendable {

    let format: AVAudioFormat?

    private struct QueuedChunk {
        let samples: [Float]
        let completion: @Sendable () -> Void
    }

    private struct InFlightChunk {
        let endFrame: Int
        let completion: @Sendable () -> Void
    }

    private let channel: FarEndPlaybackChannel
    private let converter: AVAudioConverter?
    private let channelFormat: AVAudioFormat?

    private let lock = NSLock()
    private var queue: [QueuedChunk] = []
    private var queuedOffset = 0
    private var inFlight: [InFlightChunk] = []
    private var pumpRunning = false
    private var stopped = false

    init(inputSampleRate: Double, channel: FarEndPlaybackChannel) {
        self.channel = channel
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false)
        channelFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: channel.sampleRate,
            channels: 1,
            interleaved: false)
        if inputSampleRate == channel.sampleRate {
            converter = nil
        } else if let format, let channelFormat {
            converter = AVAudioConverter(from: format, to: channelFormat)
        } else {
            converter = nil
        }
    }

    func schedule(
        buffer: AVAudioPCMBuffer,
        completion: @escaping @Sendable () -> Void
    ) {
        let samples = resample(buffer)
        enum Disposition {
            case queued(startsPump: Bool)
            case rejected
        }
        let disposition: Disposition = lock.withLock {
            guard !stopped else { return .rejected }
            queue.append(
                QueuedChunk(samples: samples, completion: completion))
            if pumpRunning { return .queued(startsPump: false) }
            pumpRunning = true
            return .queued(startsPump: true)
        }
        switch disposition {
        case .rejected:
            completion()
        case .queued(let startsPump):
            if startsPump {
                Task(priority: .userInitiated) { [weak self] in
                    await self?.pump()
                }
            }
        }
    }

    func start() throws {
        // Rendering runs with the capture transport; there is nothing
        // to start here.
    }

    func stop() {
        lock.withLock {
            stopped = true
            queue.removeAll()
            queuedOffset = 0
            inFlight.removeAll()
        }
        channel.ring.clear()
    }

    private func pump() async {
        while true {
            if lock.withLock({ stopped }) { return }

            // A channel whose transport stopped consumes nothing;
            // resolve everything as played so the utterance's drain
            // returns instead of waiting on a silent bus.
            guard channel.isActive else {
                let completions: [@Sendable () -> Void] = lock.withLock {
                    let pending =
                        inFlight.map(\.completion) + queue.map(\.completion)
                    inFlight.removeAll()
                    queue.removeAll()
                    queuedOffset = 0
                    pumpRunning = false
                    return pending
                }
                for completion in completions { completion() }
                return
            }

            feedRing()

            let due: [@Sendable () -> Void] = lock.withLock {
                let consumed = channel.ring.framesConsumed
                let ready = inFlight.prefix { $0.endFrame <= consumed }
                inFlight.removeFirst(ready.count)
                return ready.map(\.completion)
            }
            for completion in due { completion() }

            let finished: Bool = lock.withLock {
                guard queue.isEmpty, inFlight.isEmpty else { return false }
                pumpRunning = false
                return true
            }
            if finished { return }

            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func feedRing() {
        while true {
            let next: (samples: [Float], offset: Int)? = lock.withLock {
                guard !stopped, let head = queue.first else { return nil }
                return (head.samples, queuedOffset)
            }
            guard let next else { return }
            let written = channel.ring.write(next.samples, from: next.offset)
            let progressed: Bool = lock.withLock {
                guard !stopped, let head = queue.first,
                    head.samples.count == next.samples.count
                else { return false }
                queuedOffset += written
                guard queuedOffset >= head.samples.count else { return false }
                inFlight.append(
                    InFlightChunk(
                        endFrame: channel.ring.framesWritten,
                        completion: head.completion))
                queue.removeFirst()
                queuedOffset = 0
                return true
            }
            if !progressed { return }
        }
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, let channelFormat else {
            return monoSamples(of: buffer)
        }
        let ratio = channelFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up) + 64)
        guard
            let output = AVAudioPCMBuffer(
                pcmFormat: channelFormat,
                frameCapacity: outputCapacity)
        else { return [] }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if conversionError != nil { return monoSamples(of: buffer) }
        return monoSamples(of: output)
    }

    private func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else { return [] }
        return Array(
            UnsafeBufferPointer(
                start: channelData[0],
                count: Int(buffer.frameLength)))
    }
}
