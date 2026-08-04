import Foundation

/// Detect turn-ending pauses in the live audio entering a streaming
/// provider.
///
/// Runs the same trailing-silence measurement that closes local
/// dictation units — `AudioLevelAnalyzer` windows under the provider's
/// adaptive threshold — but continuously over each PCM chunk as it
/// arrives, so the endpoint fires in real time instead of on the
/// transcription cycle. Emits `.pause` once per crossing of the send
/// pause and `.audibleSpeech` at the start of each speech run; the
/// consumer applies the content gate.
public struct LiveTurnPauseDetector: Sendable {

    /// 16 kHz mono 16-bit PCM: 32000 bytes per second.
    private static let bytesPerSecond = 32_000

    /// A chunk is silent below this multiple of the tracked ambient
    /// floor. Speech runs five to ten times the floor; steady room
    /// noise stays within it.
    private static let floorMargin: Float = 2.5

    private let pauseByteCount: Int
    private var trailingSilenceBytes = 0
    private var pauseFired = false
    private var lastChunkHadSpeech = false
    private var noiseFloor: Float?

    public init(pauseSeconds: TimeInterval) {
        let bytes = Int(pauseSeconds * Double(Self.bytesPerSecond))
        // Align to whole samples so byte arithmetic never splits one.
        self.pauseByteCount = max(2, bytes - bytes % 2)
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
        // Snap the floor down to quieter ambience immediately; drift
        // it up slowly so brief speech cannot become the new floor.
        if let floor = noiseFloor {
            noiseFloor = rms < floor
                ? max(rms, 0.0001)
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
            lastChunkHadSpeech = false
        } else {
            trailingSilenceBytes = 0
            pauseFired = false
            if !lastChunkHadSpeech {
                signals.append(.audibleSpeech)
            }
            lastChunkHadSpeech = true
        }
        if trailingSilenceBytes >= pauseByteCount, !pauseFired {
            pauseFired = true
            signals.append(.pause)
        }
        return signals
    }

    /// Forget accumulated silence, as at the start of a session.
    public mutating func reset() {
        trailingSilenceBytes = 0
        pauseFired = false
        lastChunkHadSpeech = false
        noiseFloor = nil
    }
}
