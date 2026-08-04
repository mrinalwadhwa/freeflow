import Foundation
import Testing
import UnrambleKitTestSupport

@testable import UnrambleKit

@Suite("Call command gate")
struct CallCommandGateTests {

    private struct Harness {
        let gate: CallCommandGate
        let injector: MockTextInjector
        let interpreter: StubMetaCommandInterpreter
    }

    private func makeHarness(
        callActive: Bool,
        command: CallMetaCommand? = nil
    ) -> Harness {
        let injector = MockTextInjector()
        let interpreter = StubMetaCommandInterpreter(command: command)
        let gate = CallCommandGate(
            interpreter: interpreter,
            isCallTurnActive: { callActive },
            wrapping: injector)
        return Harness(
            gate: gate, injector: injector, interpreter: interpreter)
    }

    @Test("Outside a call, text passes through uninterpreted")
    func passesThroughOutsideCalls() async throws {
        let harness = makeHarness(callActive: false, command: .hangUp)

        try await harness.gate.inject(text: "hang up", into: .stub)

        #expect(harness.injector.lastInjectedText == "hang up")
        #expect(harness.interpreter.interpretedUtterances.isEmpty)
        #expect(await harness.gate.takePendingCommand() == nil)
    }

    @Test("During a call, a content turn injects normally")
    func contentTurnInjectsDuringCall() async throws {
        let harness = makeHarness(callActive: true)

        try await harness.gate.inject(
            text: "Fix the failing test.", into: .stub)

        #expect(harness.injector.lastInjectedText == "Fix the failing test.")
        #expect(
            harness.interpreter.interpretedUtterances
                == ["Fix the failing test."])
        #expect(await harness.gate.takePendingCommand() == nil)
    }

    @Test("During a call, a command is held back from injection")
    func swallowsCommandUtteranceDuringCall() async throws {
        let harness = makeHarness(callActive: true, command: .hangUp)

        try await harness.gate.inject(text: "hang up", into: .stub)

        #expect(harness.injector.injectionCount == 0)
        #expect(await harness.gate.takePendingCommand() == .hangUp)
    }

    @Test("A pending command is consumed by one take")
    func pendingCommandConsumedOnce() async throws {
        let harness = makeHarness(callActive: true, command: .hangUp)

        try await harness.gate.inject(text: "hang up", into: .stub)

        #expect(await harness.gate.takePendingCommand() == .hangUp)
        #expect(await harness.gate.takePendingCommand() == nil)
    }

    @Test("Reset discards a pending command")
    func resetDiscardsPendingCommand() async throws {
        let harness = makeHarness(callActive: true, command: .hangUp)

        try await harness.gate.inject(text: "hang up", into: .stub)
        await harness.gate.reset()

        #expect(await harness.gate.takePendingCommand() == nil)
    }

    @Test("During a call, a hallucination loop is vetoed from injection")
    func vetoesDegenerateTranscriptDuringCall() async throws {
        let harness = makeHarness(callActive: true)
        let loop = Array(
            repeating: "I'm not sure if I'm going to be able to do it.",
            count: 5
        ).joined(separator: " ")

        try await harness.gate.inject(text: loop, into: .stub)

        #expect(harness.injector.injectionCount == 0)
        #expect(await harness.gate.takePendingCommand() == nil)
    }

    @Test("Outside a call, a repetitive text still passes through")
    func repetitiveTextPassesThroughOutsideCalls() async throws {
        let harness = makeHarness(callActive: false)
        let loop = Array(
            repeating: "I'm not sure if I'm going to be able to do it.",
            count: 5
        ).joined(separator: " ")

        try await harness.gate.inject(text: loop, into: .stub)

        #expect(harness.injector.injectionCount == 1)
    }
}
