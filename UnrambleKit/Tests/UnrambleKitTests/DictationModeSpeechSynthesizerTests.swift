import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Dictation-mode speech synthesizer")
struct DictationModeSpeechSynthesizerTests {

    @Test("Cloud mode routes speech to the cloud voice")
    func cloudModeRoutesToCloud() async {
        let local = MockSpeechSynthesizer()
        let cloud = MockSpeechSynthesizer()
        let router = DictationModeSpeechSynthesizer(
            localVoice: local, cloudVoice: cloud, isCloudMode: { true })

        await router.speak("Hello.")

        #expect(cloud.spokenTexts == ["Hello."])
        #expect(local.spokenTexts.isEmpty)
    }

    @Test("Local mode routes speech to the local voice")
    func localModeRoutesToLocal() async {
        let local = MockSpeechSynthesizer()
        let cloud = MockSpeechSynthesizer()
        let router = DictationModeSpeechSynthesizer(
            localVoice: local, cloudVoice: cloud, isCloudMode: { false })

        await router.speak("Hello.")

        #expect(local.spokenTexts == ["Hello."])
        #expect(cloud.spokenTexts.isEmpty)
    }

    @Test("Stop reaches both voices")
    func stopReachesBoth() {
        let local = MockSpeechSynthesizer()
        let cloud = MockSpeechSynthesizer()
        let router = DictationModeSpeechSynthesizer(
            localVoice: local, cloudVoice: cloud, isCloudMode: { true })

        router.stopSpeaking()

        #expect(local.stopCount == 1)
        #expect(cloud.stopCount == 1)
    }
}
