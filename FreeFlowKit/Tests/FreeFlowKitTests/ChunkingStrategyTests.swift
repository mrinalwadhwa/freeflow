import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Tests for TimeAndSilenceChunkingStrategy.
//
// The strategy returns true when the provider should commit the current
// chunk. Commit fires on two triggers: elapsed time exceeds the hard
// maximum, or the speaker has gone silent after accumulating enough audio
// to justify an early commit.
// ---------------------------------------------------------------------------

@Suite("TimeAndSilenceChunkingStrategy")
struct ChunkingStrategyTests {

    @Test("returns false immediately after a commit while speaking")
    func holdsDuringActiveSpeech() {
        let strategy = TimeAndSilenceChunkingStrategy()
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 0.1, isSpeaking: true) == false)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 60.0, isSpeaking: true) == false)
    }

    @Test("commits on the hard maximum regardless of speech state")
    func commitsAtMaximum() {
        let strategy = TimeAndSilenceChunkingStrategy()
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 300.0, isSpeaking: true) == true)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 400.0, isSpeaking: false) == true)
    }

    @Test("holds below the hard maximum while speaking")
    func holdsBelowMaximum() {
        let strategy = TimeAndSilenceChunkingStrategy()
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 299.0, isSpeaking: true) == false)
    }

    @Test("commits early on silence once past the minimum")
    func commitsEarlyOnSilence() {
        let strategy = TimeAndSilenceChunkingStrategy()
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 180.0, isSpeaking: false) == true)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 240.0, isSpeaking: false) == true)
    }

    @Test("holds during silence before the minimum elapses")
    func holdsDuringBriefPause() {
        let strategy = TimeAndSilenceChunkingStrategy()
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 0.5, isSpeaking: false) == false)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 179.0, isSpeaking: false) == false)
    }

    @Test("custom configuration overrides the defaults")
    func honorsCustomConfiguration() {
        let strategy = TimeAndSilenceChunkingStrategy(
            maxChunkSeconds: 8, minSilenceCommitSeconds: 2)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 7.9, isSpeaking: true) == false)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 8.0, isSpeaking: true) == true)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 2.0, isSpeaking: false) == true)
        #expect(
            strategy.shouldCommitNow(
                sinceLastCommitSeconds: 1.9, isSpeaking: false) == false)
    }
}
