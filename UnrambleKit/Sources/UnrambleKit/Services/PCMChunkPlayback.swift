import AVFoundation
import Foundation

/// Plays a growing sequence of PCM chunks gaplessly.
///
/// Chunks are scheduled as they finish generating; the player consumes
/// them in order, so playback of early chunks overlaps generation of
/// later ones. `drain` suspends until every scheduled chunk has played
/// or the playback was stopped.
final class PCMChunkPlayback: @unchecked Sendable {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat?

    private let lock = NSLock()
    private var pendingBuffers = 0
    private var finishedScheduling = false
    private var stopped = false
    private var drainContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    init(sampleRate: Double) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false)
        if let format {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }

    func schedule(samples: [Float]) throws {
        guard let format,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw PCMChunkPlaybackError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0]
                .update(from: source.baseAddress!, count: samples.count)
        }

        let shouldStart: Bool = lock.withLock {
            guard !stopped else { return false }
            pendingBuffers += 1
            if !started {
                started = true
                return true
            }
            return false
        }
        if shouldStart {
            do {
                try engine.start()
            } catch {
                lock.withLock { pendingBuffers -= 1 }
                throw error
            }
            player.play()
        }

        player.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            self?.bufferFinished()
        }
    }

    /// Suspend until everything scheduled has played, or `stop` ran.
    func drain() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                finishedScheduling = true
                if stopped || pendingBuffers == 0 {
                    return true
                }
                drainContinuation = continuation
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    /// Silence playback immediately and release any drain waiter. The
    /// player's completion handlers may also fire on stop; both paths
    /// resume the waiter at most once.
    func stop() {
        let (wasStarted, continuation):
            (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                stopped = true
                pendingBuffers = 0
                let waiter = drainContinuation
                drainContinuation = nil
                return (started, waiter)
            }
        if wasStarted {
            player.stop()
            engine.stop()
        }
        continuation?.resume()
    }

    private func bufferFinished() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            pendingBuffers = max(0, pendingBuffers - 1)
            guard pendingBuffers == 0, finishedScheduling else { return nil }
            let waiter = drainContinuation
            drainContinuation = nil
            return waiter
        }
        continuation?.resume()
    }
}

enum PCMChunkPlaybackError: Error {
    case bufferAllocationFailed
}
