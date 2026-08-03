import Foundation

/// Routes read-aloud speech to the voice matching the dictation mode.
///
/// The mode governs the whole pipeline: local mode keeps everything on
/// the machine, including the voice; cloud mode's users chose cloud
/// processing over locality — often on machines that cannot run the
/// local model — so their reads use the cloud voice. The mode is read
/// per utterance, so a mode switch changes the voice without rebuilding
/// the read session graph.
public final class DictationModeSpeechSynthesizer: SpeechSynthesizing,
    @unchecked Sendable
{

    private let localVoice: any SpeechSynthesizing
    private let cloudVoice: any SpeechSynthesizing
    private let isCloudMode: @Sendable () -> Bool

    public init(
        localVoice: any SpeechSynthesizing,
        cloudVoice: any SpeechSynthesizing,
        isCloudMode: @escaping @Sendable () -> Bool
    ) {
        self.localVoice = localVoice
        self.cloudVoice = cloudVoice
        self.isCloudMode = isCloudMode
    }

    public func speak(_ text: String) async {
        if isCloudMode() {
            await cloudVoice.speak(text)
        } else {
            await localVoice.speak(text)
        }
    }

    public func stopSpeaking() {
        // Stop both: the mode may have flipped mid-utterance, and
        // stopping an idle voice is a no-op.
        localVoice.stopSpeaking()
        cloudVoice.stopSpeaking()
    }
}
