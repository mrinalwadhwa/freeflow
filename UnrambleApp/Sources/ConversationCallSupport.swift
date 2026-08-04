import Foundation
import UnrambleKit

/// Synchronous call-activity flag for the dictation key tap.
///
/// The event tap must decide synchronously whether a press belongs to
/// the call or to push-to-talk — an async detour would reorder press
/// and release for the pipeline driver — so the app mirrors the call's
/// state into this lock-guarded flag.
final class CallActivityFlag: @unchecked Sendable {

    private let lock = NSLock()
    private var _isActive = false

    var isActive: Bool {
        lock.withLock { _isActive }
    }

    func setActive(_ active: Bool) {
        lock.withLock { _isActive = active }
    }
}

/// Forward pipeline calls to the current dictation mode's pipeline.
///
/// A dictation-mode switch rebuilds the pipeline; routing through this
/// proxy lets the call coordinator, built once, capture each turn with
/// whatever pipeline is current — the mode change applies from the
/// next turn.
final class CurrentPipelineProxy: PipelineProviding, @unchecked Sendable {

    private let current: @Sendable () async -> (any PipelineProviding)?

    init(current: @escaping @Sendable () async -> (any PipelineProviding)?) {
        self.current = current
    }

    @discardableResult
    func activate() async -> DictationSessionID? {
        await current()?.activate()
    }

    @discardableResult
    func activate(
        releaseBoundary: AudioCaptureReleaseBoundary
    ) async -> DictationSessionID? {
        await current()?.activate(releaseBoundary: releaseBoundary)
    }

    func complete() async {
        await current()?.complete()
    }

    func complete(sessionID: DictationSessionID) async {
        await current()?.complete(sessionID: sessionID)
    }

    func complete(
        sessionID: DictationSessionID,
        releaseHostTime: UInt64
    ) async {
        await current()?.complete(
            sessionID: sessionID,
            releaseHostTime: releaseHostTime)
    }

    func cancel() async {
        await current()?.cancel()
    }

    func cancel(sessionID: DictationSessionID) async {
        await current()?.cancel(sessionID: sessionID)
    }

    var state: RecordingState {
        get async { await current()?.state ?? .idle }
    }

    var currentSessionID: DictationSessionID? {
        get async { await current()?.currentSessionID }
    }
}

/// The call's cues reuse the short dictation sounds; longer sounds
/// measurably delayed feedback when previously tried. The send cue
/// marks the moment a turn goes, the reply cue precedes speech, and
/// the done cue marks a tool-only turn.
struct DictationSoundCallCues: CallCuePlaying, @unchecked Sendable {

    let feedback: SoundFeedbackProvider

    func playSendCue() {
        feedback.playStopSound()
    }

    func playReplyCue() {
        feedback.playStartSound()
    }

    func playDoneCue() {
        feedback.playStopSound()
    }
}
