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

    /// A run is strong once its peak clears this multiple of the
    /// floor. Audible marks any sustained sound; strong marks the
    /// level contour of a voice, and only strong runs may become
    /// sendable content.
    private static let strongFloorMultiple: Float = 5

    /// A strong run's peak must also clear this absolute level in
    /// the raw microphone scale, so a near-silent room cannot make
    /// whispers of its own noise. Measured live: a quiet far-field
    /// voice can run as low as 0.009 raw; the sustained-run and
    /// floor-multiple gates, not this minimum, carry the burden of
    /// separating speech from noise in a session with nothing
    /// playing.
    private static let minimumStrongRMS: Float = 0.008

    /// An emphatic run additionally clears the level that
    /// echo-cancelled narration residual can reach — measured live
    /// at or below 0.019 raw — so only emphatic runs may take the
    /// floor from a playing voice. A voice quieter than the
    /// residual is physically indistinguishable from it on level
    /// alone; the buttons remain the barge for such a voice.
    private static let minimumEmphaticRMS: Float = 0.03

    /// The floor's ceiling in the raw scale: long loud speech drifts
    /// the floor upward one percent per chunk, and this cap keeps
    /// the drift from ever reclassifying speech as ambience.
    private static let maximumFloor: Float = 0.01

    private let pauseByteCount: Int
    private let finalPauseByteCount: Int
    private let sustainByteCount: Int
    private var trailingSilenceBytes = 0
    private var runAudibleBytes = 0
    private var runPeak: Float = 0
    private var runStrongBytes = 0
    private var pauseFired = false
    private var finalPauseFired = false
    private var speechSignaled = false
    private var strongSignaled = false
    private var emphaticSignaled = false
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
    ///
    /// `gain` is the software gain baked into the chunk's samples;
    /// the detector divides it out so every level, floor, and
    /// threshold lives in the raw microphone scale. Capture applies
    /// up to sixteen-fold gain for far-field microphones, and
    /// thresholds in the amplified scale do not mean what their
    /// names imply.
    public mutating func observe(
        chunk: Data,
        threshold: Float,
        gain: Float = 1
    ) -> [TurnSignal] {
        guard !chunk.isEmpty else { return [] }

        let measured = AudioLevelAnalyzer.rmsLevel(pcm16: chunk)
        let rms = gain > 0 ? measured / gain : measured
        // The floor approximates recent typical ambience, not its
        // minimum: it decays a few percent per chunk and rises about
        // as slowly. Sub-second dips therefore cannot drag it down —
        // one anomalous dip must not redefine the room, and a
        // fluctuating residual (echo-cancelled playback leaves a hash
        // whose swells run several times its own dips) must not have
        // its swells reclassified as speech — while brief speech
        // cannot become the new floor on the way up.
        if let floor = noiseFloor {
            noiseFloor = rms < floor
                ? max(floor * 0.98, rms, 0.0001)
                : min(floor * 1.01, Self.maximumFloor)
        } else {
            // Cap the initial floor: a session that opens mid-speech
            // must not adopt speech loudness as its ambience.
            noiseFloor = min(max(rms, 0.0001), Self.maximumFloor)
        }
        let silenceCeiling = max(threshold, (noiseFloor ?? 0) * Self.floorMargin)

        var signals: [TurnSignal] = []
        let strongCeiling = max(
            (noiseFloor ?? 0) * Self.strongFloorMultiple,
            Self.minimumStrongRMS)
        let emphaticCeiling = max(
            (noiseFloor ?? 0) * Self.strongFloorMultiple,
            Self.minimumEmphaticRMS)
        if rms < silenceCeiling {
            if runAudibleBytes > 0 {
                Log.debug(
                    "[TurnRun] end bytes=\(runAudibleBytes) "
                        + "peak=\(runPeak) "
                        + "aboveStrongBytes=\(runStrongBytes)")
            }
            trailingSilenceBytes += chunk.count
            runAudibleBytes = 0
            runPeak = 0
            runStrongBytes = 0
            speechSignaled = false
            strongSignaled = false
            emphaticSignaled = false
        } else {
            if runAudibleBytes == 0 {
                Log.debug(
                    "[TurnRun] start rms=\(rms) "
                        + "floor=\(noiseFloor ?? 0) "
                        + "ceiling=\(silenceCeiling) "
                        + "strong=\(strongCeiling)")
            }
            trailingSilenceBytes = 0
            pauseFired = false
            finalPauseFired = false
            runAudibleBytes += chunk.count
            runPeak = max(runPeak, rms)
            if rms >= strongCeiling {
                runStrongBytes += chunk.count
            }
            if !speechSignaled, runAudibleBytes >= sustainByteCount {
                speechSignaled = true
                signals.append(.audibleSpeech)
            }
            if speechSignaled, !strongSignaled, runPeak >= strongCeiling {
                strongSignaled = true
                Log.debug(
                    "[TurnRun] strong bytes=\(runAudibleBytes) "
                        + "peak=\(runPeak) "
                        + "aboveStrongBytes=\(runStrongBytes)")
                signals.append(.strongSpeech)
            }
            if speechSignaled, !emphaticSignaled, runPeak >= emphaticCeiling {
                emphaticSignaled = true
                Log.debug(
                    "[TurnRun] emphatic bytes=\(runAudibleBytes) "
                        + "peak=\(runPeak)")
                signals.append(.emphaticSpeech)
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
        runPeak = 0
        runStrongBytes = 0
        pauseFired = false
        finalPauseFired = false
        speechSignaled = false
        strongSignaled = false
        emphaticSignaled = false
        noiseFloor = nil
    }
}
