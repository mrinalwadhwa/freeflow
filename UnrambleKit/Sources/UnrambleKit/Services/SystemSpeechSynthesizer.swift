import Foundation

#if canImport(AVFoundation)
    import AVFoundation
#endif

/// Speaks text through the system speech synthesizer.
///
/// Wraps one long-lived `AVSpeechSynthesizer` so callers depend only on
/// `SpeechSynthesizing`; a local neural TTS engine can replace this
/// implementation without touching the coordinator.
///
/// Waiting `speak` calls are keyed by utterance identity, so a stale
/// delegate callback can never resume a newer call. `stopSpeaking` resumes
/// waiters directly instead of relying on a cancel callback, because an
/// utterance stopped before it starts may never receive one.
public final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing,
    @unchecked Sendable
{

    private let lock = NSLock()

    #if canImport(AVFoundation)
        private var synthesizer: AVSpeechSynthesizer?
        private var pending:
            [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]

        private func sharedSynthesizerLocked() -> AVSpeechSynthesizer {
            if let synthesizer { return synthesizer }
            let created = AVSpeechSynthesizer()
            created.delegate = self
            synthesizer = created
            return created
        }
    #endif

    public override init() {
        super.init()
    }

    public func speak(_ text: String) async {
        #if canImport(AVFoundation)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            await withCheckedContinuation { continuation in
                let utterance = AVSpeechUtterance(string: trimmed)
                let (synthesizer, stale) = lock.withLock {
                    () -> (AVSpeechSynthesizer, [CheckedContinuation<Void, Never>]) in
                    // A still-pending previous call means the caller violated
                    // one-session-at-a-time; resume it rather than leak it.
                    let stale = Array(pending.values)
                    pending = [ObjectIdentifier(utterance): continuation]
                    return (sharedSynthesizerLocked(), stale)
                }
                for waiter in stale {
                    waiter.resume()
                }
                synthesizer.stopSpeaking(at: .immediate)
                synthesizer.speak(utterance)
            }
        #endif
    }

    public func stopSpeaking() {
        #if canImport(AVFoundation)
            let (synthesizer, waiting) = lock.withLock {
                () -> (AVSpeechSynthesizer?, [CheckedContinuation<Void, Never>]) in
                let waiting = Array(pending.values)
                pending = [:]
                return (self.synthesizer, waiting)
            }
            synthesizer?.stopSpeaking(at: .immediate)
            for waiter in waiting {
                waiter.resume()
            }
        #endif
    }

    #if canImport(AVFoundation)
        private func finishUtterance(_ utterance: AVSpeechUtterance) {
            let continuation = lock.withLock {
                pending.removeValue(forKey: ObjectIdentifier(utterance))
            }
            continuation?.resume()
        }
    #endif
}

#if canImport(AVFoundation)
    extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
        public func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            didFinish utterance: AVSpeechUtterance
        ) {
            finishUtterance(utterance)
        }

        public func speechSynthesizer(
            _ synthesizer: AVSpeechSynthesizer,
            didCancel utterance: AVSpeechUtterance
        ) {
            finishUtterance(utterance)
        }
    }
#endif
