import Foundation
import UnrambleKit

/// Mock speech synthesizer that records scripts and can block until stopped.
public final class MockSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {

    private let lock = NSLock()
    private var _spokenTexts: [String] = []
    private var _stopCount = 0
    private var _blocksUntilStopped = false
    private var pendingSpeech: CheckedContinuation<Void, Never>?
    private var speakingWaiters: [CheckedContinuation<Void, Never>] = []
    private var _isSpeaking = false

    public init() {}

    public var spokenTexts: [String] {
        lock.withLock { _spokenTexts }
    }

    public var stopCount: Int {
        lock.withLock { _stopCount }
    }

    /// When true, `speak` suspends until `stopSpeaking` is called, so tests
    /// can exercise stopping mid-speech deterministically.
    public var blocksUntilStopped: Bool {
        get { lock.withLock { _blocksUntilStopped } }
        set { lock.withLock { _blocksUntilStopped = newValue } }
    }

    public func speak(_ text: String) async {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            _spokenTexts.append(text)
            _isSpeaking = true
            let waiting = speakingWaiters
            speakingWaiters = []
            return waiting
        }
        for waiter in waiters {
            waiter.resume()
        }

        if blocksUntilStopped {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    guard _isSpeaking else { return true }
                    pendingSpeech = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        lock.withLock { _isSpeaking = false }
    }

    public func stopSpeaking() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            _stopCount += 1
            _isSpeaking = false
            let continuation = pendingSpeech
            pendingSpeech = nil
            return continuation
        }
        pending?.resume()
    }

    /// Suspend until `speak` has been entered at least once.
    ///
    /// Resumes immediately when any utterance has already been recorded,
    /// so this only distinguishes "not yet spoken" from "has spoken"; it
    /// is not a wait for a *particular* utterance to start.
    public func waitUntilSpeaking() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if _isSpeaking || !_spokenTexts.isEmpty { return true }
                speakingWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }
}
