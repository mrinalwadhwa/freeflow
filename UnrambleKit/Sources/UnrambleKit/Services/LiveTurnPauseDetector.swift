import Foundation

/// Detect turn-ending pauses in the live audio entering a streaming
/// provider.
///
/// Runs the same trailing-silence measurement that closes local
/// dictation units — `AudioLevelAnalyzer` windows under the provider's
/// adaptive threshold — but continuously over each PCM chunk as it
/// arrives, so the endpoint fires in real time instead of on the
/// transcription cycle. Emits `.pause` once per crossing of the send
/// pause and `.audibleSpeech` once per speech run that sustains past
/// the sustain window — a knock, cough, or door slam is a burst that
/// never sustains, so impulsive noise cannot become a sendable turn
/// for the recognizer to hallucinate text from. The consumer applies
/// the content gate.
public struct LiveTurnPauseDetector: Sendable {

    /// 16 kHz mono 16-bit PCM: 32000 bytes per second.
    private static let bytesPerSecond = 32_000

    /// A chunk is silent below this multiple of the tracked ambient
    /// floor. Speech runs five to ten times the floor; steady room
    /// noise stays within it.
    private static let floorMargin: Float = 2.5

    private let pauseByteCount: Int
    private let finalPauseByteCount: Int
    private let sustainByteCount: Int
    private var trailingSilenceBytes = 0
    private var runAudibleBytes = 0
    private var pauseFired = false
    private var finalPauseFired = false
    private var speechSignaled = false
    private var noiseFloor: Float?

    public init(
        pauseSeconds: TimeInterval,
        sustainSeconds: TimeInterval = 0.4,
        finalPauseSeconds: TimeInterval? = nil
    ) {
        let bytes = Int(pauseSeconds * Double(Self.bytesPerSecond))
        // Align to whole samples so byte arithmetic never splits one.
        self.pauseByteCount = max(2, bytes - bytes % 2)
        let sustainBytes = Int(sustainSeconds * Double(Self.bytesPerSecond))
        self.sustainByteCount = max(0, sustainBytes - sustainBytes % 2)
        // A longer final pause re-fires `.pause` once more, so a
        // consumer that held a mid-clause endpoint open gets a second
        // chance to close the turn.
        let finalSeconds = max(finalPauseSeconds ?? pauseSeconds, pauseSeconds)
        let finalBytes = Int(finalSeconds * Double(Self.bytesPerSecond))
        self.finalPauseByteCount = max(2, finalBytes - finalBytes % 2)
    }

    /// Observe one PCM chunk and return the signals it produced, in
    /// order. The threshold marks guaranteed silence; the detector
    /// additionally tracks the session's ambient noise floor, because
    /// a real microphone idles well above the dictation stack's
    /// dead-silence threshold and would otherwise never pause.
    public mutating func observe(
        chunk: Data,
        threshold: Float
    ) -> [TurnSignal] {
        guard !chunk.isEmpty else { return [] }

        let rms = AudioLevelAnalyzer.rmsLevel(pcm16: chunk)
        // Decay the floor toward quieter ambience gradually — one
        // anomalous dip must not redefine the room and reclassify
        // steady ambient noise as speech — and drift it up slowly so
        // brief speech cannot become the new floor.
        if let floor = noiseFloor {
            noiseFloor = rms < floor
                ? max(floor * 0.7, rms, 0.0001)
                : min(floor * 1.01, 0.05)
        } else {
            // Cap the initial floor: a session that opens mid-speech
            // must not adopt speech loudness as its ambience.
            noiseFloor = min(max(rms, 0.0001), 0.05)
        }
        let silenceCeiling = max(threshold, (noiseFloor ?? 0) * Self.floorMargin)

        var signals: [TurnSignal] = []
        if rms < silenceCeiling {
            trailingSilenceBytes += chunk.count
            runAudibleBytes = 0
            speechSignaled = false
        } else {
            trailingSilenceBytes = 0
            pauseFired = false
            finalPauseFired = false
            runAudibleBytes += chunk.count
            if !speechSignaled, runAudibleBytes >= sustainByteCount {
                speechSignaled = true
                signals.append(.audibleSpeech)
            }
        }
        if trailingSilenceBytes >= pauseByteCount, !pauseFired {
            pauseFired = true
            signals.append(.pause)
        }
        if finalPauseByteCount > pauseByteCount,
            trailingSilenceBytes >= finalPauseByteCount, !finalPauseFired
        {
            finalPauseFired = true
            signals.append(.pause)
        }
        return signals
    }

    /// Forget accumulated silence, as at the start of a session.
    public mutating func reset() {
        trailingSilenceBytes = 0
        runAudibleBytes = 0
        pauseFired = false
        finalPauseFired = false
        speechSignaled = false
        noiseFloor = nil
    }
}
