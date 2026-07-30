import Foundation
import Testing

@testable import UnrambleKit

@Suite("Dictation composition factory")
struct DictationCompositionFactoryTests {

    @Test("Cloud composition builds a cloud backend and forwards the handler")
    func cloudComposition() {
        let composition = DictationCompositionFactory.makeCloud(
            apiKey: "sk-test", onSessionExpired: {})

        guard case .cloud = composition.backend else {
            Issue.record("expected a cloud backend")
            return
        }
        #expect(composition.localRuntime == nil)
        #expect(composition.onSessionExpired != nil)
    }

    @Test("Cloud composition allows a nil expiry handler")
    func cloudCompositionNilHandler() {
        let composition = DictationCompositionFactory.makeCloud(
            apiKey: "sk-test", onSessionExpired: nil)

        guard case .cloud = composition.backend else {
            Issue.record("expected a cloud backend")
            return
        }
        #expect(composition.onSessionExpired == nil)
    }

    @Test("Local STT defaults to the current Nemotron path")
    func localSTTDefaultsToNemotron() {
        #expect(
            DictationCompositionFactory.localSTTKind(environment: [:])
                == .nemotron)
    }

    @Test("Cohere MLX is selected only by the internal flag")
    func cohereMLXSelection() {
        #expect(
            DictationCompositionFactory.localSTTKind(
                environment: ["UNRAMBLE_LOCAL_STT": " cohere-mlx "])
                == .cohereMLX)
        #expect(
            DictationCompositionFactory.localSTTKind(
                environment: ["UNRAMBLE_LOCAL_STT": "cohere"])
                == .nemotron)
    }

    @Test("Nemotron keeps the existing eleven-second polish cap")
    func nemotronUnitPolicy() {
        let policy = DictationCompositionFactory.localUnitPolicy(
            for: .nemotron)

        #expect(
            policy.maximumUnitBytes
                == 11 * LocalUnitPolicy.sourceBytesPerSecond)
    }

    @Test("Cohere gives Qwen complete thoughts with a bounded fallback")
    func cohereUnitPolicy() {
        let policy = DictationCompositionFactory.localUnitPolicy(
            for: .cohereMLX)

        #expect(
            policy.maximumUnitBytes
                == 90 * LocalUnitPolicy.sourceBytesPerSecond)
    }

    @Test("Cycle interval defaults to three seconds without an override")
    func cycleIntervalDefault() {
        #expect(DictationCompositionFactory.cycleInterval(from: [:]) == 3)
    }

    @Test("Cycle interval honors a positive override")
    func cycleIntervalOverride() {
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "1.5"]) == 1.5)
    }

    @Test("Cycle interval ignores a non-positive or invalid override")
    func cycleIntervalRejectsInvalid() {
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "0"]) == 3)
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "-2"]) == 3)
        #expect(
            DictationCompositionFactory.cycleInterval(
                from: ["UNRAMBLE_CYCLE_INTERVAL": "not-a-number"]) == 3)
    }
}
