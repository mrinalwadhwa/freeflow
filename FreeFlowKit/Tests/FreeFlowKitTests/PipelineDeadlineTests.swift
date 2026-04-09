import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Tests for DictationPipeline.pipelineDeadline.
//
// The deadline is the hard cap on the pipeline task's total duration. It
// must scale with the recording duration so long dictations do not race
// the force-reset and drop valid transcripts.
// ---------------------------------------------------------------------------

@Suite("DictationPipeline – pipelineDeadline")
struct PipelineDeadlineTests {

    @Test("zero recording duration returns the baseline budget")
    func zeroRecording() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 0)
        #expect(d == 45.0)
    }

    @Test("two second recording gets baseline + duration")
    func twoSecondRecording() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 2.0)
        #expect(d == 47.0)
    }

    @Test("recordingDuration + 45 formula applies in the middle range")
    func middleRange() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 30)
        #expect(d == 75.0)
    }

    @Test("130 second monologue gets 175 second deadline")
    func longMonologue() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 130)
        #expect(d == 175.0)
    }

    @Test("deadline is capped at 300 seconds")
    func cappedAtCeiling() {
        let d = DictationPipeline.pipelineDeadline(forRecordingDuration: 600)
        #expect(d == 300.0)
    }
}
