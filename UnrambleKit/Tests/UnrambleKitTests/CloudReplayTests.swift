import Foundation
import Testing

@testable import UnrambleKit

// Replay a directory of saved WAVs through the REAL cloud dictation path —
// OpenAI Realtime streaming STT (gpt-realtime-2.1) plus the on-connection cloud
// polish — and record the raw transcript and polished output per file. This is
// the cloud analogue of StreamingReplay (local on-device path), so the two can
// be compared file by file.
//
// Hits the live OpenAI API, so it is gated and inert unless explicitly enabled:
//   /tmp/unramble-test-cloud-replay   must exist to run at all
//   OPENAI_API_KEY                    must be set in the environment
//   UNRAMBLE_TEST_OPENAI=1            opens the test bundle's network guard
//
// Run via swift test (forwards environment; no Metal needed):
//   touch /tmp/unramble-test-cloud-replay
//   echo <wavdir> >/tmp/unramble-replay-dir
//   OPENAI_API_KEY=sk-... UNRAMBLE_TEST_OPENAI=1 \
//     swift test --filter CloudReplay
//
// Inputs (flag files, matching StreamingReplay):
//   /tmp/unramble-replay-dir    directory of sample WAVs (required)
//   /tmp/unramble-replay-only   a single WAV basename to replay alone
//   /tmp/unramble-replay-prompt optional path to a base polish prompt
//   /tmp/unramble-cloud-replay-output optional output log path
//
// Output: /tmp/unramble-cloud-replay.log — one [[CLOUD]] JSON record per WAV
//   {"wav","items","secs","raw","out"} (or {"wav","error"} on failure).

@Suite("Cloud replay", .serialized)
struct CloudReplay {

    @Test("Replay saved WAVs through the cloud path")
    func replay() async throws {
        guard FileManager.default.fileExists(
            atPath: "/tmp/unramble-test-cloud-replay")
        else { return }

        let readFlag = { (path: String) -> String? in
            guard let s = try? String(contentsOfFile: path, encoding: .utf8)
            else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            !apiKey.isEmpty
        else {
            Issue.record("set OPENAI_API_KEY to replay through the cloud path")
            return
        }
        guard let dirPath = readFlag("/tmp/unramble-replay-dir") else {
            Issue.record(
                "set /tmp/unramble-replay-dir to a directory of sample WAVs")
            return
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let only = readFlag("/tmp/unramble-replay-only")
        let promptPath = readFlag("/tmp/unramble-replay-prompt")
        let promptOverride = try promptPath.map {
            try String(contentsOfFile: $0, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let outputPath = readFlag("/tmp/unramble-cloud-replay-output")
            ?? "/tmp/unramble-cloud-replay.log"

        var wavs = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path))
            ?? []).filter { $0.hasSuffix(".wav") }.sorted()
        if let only { wavs = wavs.filter { $0 == only } }
        guard !wavs.isEmpty else {
            Issue.record("no matching WAVs under \(dir.path)")
            return
        }

        let log = CloudReplayLog(path: outputPath)
        let realtimeModel = OpenAIStreamingProvider.defaultRealtimeModel
        let sttModel = "gpt-4o-mini-transcribe"
        log.log(
            "=== cloud replay (\(wavs.count) files, model=\(realtimeModel), "
                + "policy=\(promptPath == nil ? "default" : "override")) ===")

        for name in wavs {
            Log.debug("[[WAV]] \(name)")
            let started = Date()
            do {
                let data = try Data(contentsOf: dir.appendingPathComponent(name))
                let fixture = try WAVFixture(data: data)

                let recorder = CloudReplayRecorder()
                let provider = OpenAIStreamingProvider(
                    apiKeyProvider: { apiKey },
                    realtimeModel: realtimeModel,
                    sttModel: sttModel,
                    commitPolicy: RealtimeCommitPolicy(),
                    maxUnresolvedItems: 2,
                    evidenceObserver: { await recorder.record($0) },
                    polishInstructionsOverride: promptOverride)
                let sessionID = DictationSessionID()

                do {
                    try await provider.startStreaming(
                        sessionID: sessionID,
                        context: .empty,
                        language: "en",
                        micProximity: .nearField)
                    for chunk in fixture.pcm.replayChunks(maximumByteCount: 4_096) {
                        try await provider.sendAudio(chunk, sessionID: sessionID)
                    }
                    let polished = try await provider.finishStreaming(
                        sessionID: sessionID)
                    let snapshots = await recorder.snapshots()
                    await provider.disconnect()

                    let raw = snapshots.last?.items
                        .map(\.transcript)
                        .joined(separator: " ") ?? ""
                    let items = snapshots.last?.items.count ?? 0
                    let secs = Date().timeIntervalSince(started)
                    log.record(
                        wav: name, items: items, secs: secs, raw: raw,
                        out: polished)
                } catch {
                    await provider.disconnect()
                    throw error
                }
            } catch {
                log.recordError(wav: name, error: "\(error)")
            }
        }
    }

    /// Compare the production prompt with isolated prompt candidates using
    /// text-only Realtime requests. This deliberately bypasses ASR while
    /// retaining production preprocessing, fidelity guards, and postprocessing.
    ///
    /// Enable explicitly:
    ///   touch /tmp/unramble-test-realtime-text-ablation
    ///   echo <corpus.json> >/tmp/unramble-ablation-corpus
    ///   echo production >/tmp/unramble-ablation-prompt
    ///     # or write the path of a prompt text file instead
    ///   echo <output.jsonl> >/tmp/unramble-ablation-output
    ///   OPENAI_API_KEY=... UNRAMBLE_TEST_OPENAI=1 swift test --filter CloudReplay
    @Test("Replay a private text corpus with an isolated Realtime prompt")
    func replayTextPromptAblation() async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(
            atPath: "/tmp/unramble-test-realtime-text-ablation")
        else { return }

        let environment = ProcessInfo.processInfo.environment
        let apiKey = try #require(environment["OPENAI_API_KEY"])
        #expect(!apiKey.isEmpty)

        let corpusPath = try #require(
            textAblationFlag("/tmp/unramble-ablation-corpus"))
        let promptSetting = try #require(
            textAblationFlag("/tmp/unramble-ablation-prompt"))
        let outputPath = textAblationFlag("/tmp/unramble-ablation-output")
            ?? "/tmp/unramble-realtime-text-ablation.jsonl"

        let corpus = try JSONDecoder().decode(
            RealtimeTextAblationCorpus.self,
            from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let prompt: String
        let promptID: String
        if promptSetting == "production" {
            prompt = try productionRealtimeInstructions()
            promptID = "production"
        } else {
            prompt = try String(
                contentsOfFile: promptSetting, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            promptID = URL(fileURLWithPath: promptSetting)
                .deletingPathExtension().lastPathComponent
        }
        #expect(!prompt.isEmpty)

        let log = RealtimeTextAblationLog(path: outputPath)
        log.header(
            model: OpenAIStreamingProvider.defaultRealtimeModel,
            promptID: promptID,
            caseCount: corpus.cases.count,
            corpusSHA256: corpus.casesSHA256)

        var outcomesByPreparedInput: [String: RealtimeTextAblationOutcome] = [:]
        for entry in corpus.cases {
            let started = Date()
            let prepared = PolishPipeline.substituteDictatedPunctuation(
                entry.input, casual: false, precedingText: nil)
            if let outcome = outcomesByPreparedInput[prepared] {
                log.record(
                    entry: entry,
                    promptID: promptID,
                    prepared: prepared,
                    outcome: outcome,
                    reused: true,
                    seconds: 0)
                continue
            }
            do {
                let rawModel = try await realtimeTextPolish(
                    apiKey: apiKey,
                    model: OpenAIStreamingProvider.defaultRealtimeModel,
                    instructions: prompt,
                    transcript: prepared)
                let guarded = OpenAIRealtimeSessionDriver.validatedRealtimePolish(
                    rawModel, rawTranscript: prepared)
                let final = guarded.isEmpty ? guarded
                    : PolishPipeline.ensureTerminalPunctuation(
                        PolishPipeline.insertVocativeComma(
                            PolishPipeline.normalizeFormatting(
                                PolishPipeline.stripKeepTags(
                                    guarded, casual: false),
                                casual: false)),
                        casual: false)
                let outcome = RealtimeTextAblationOutcome(
                    rawModel: rawModel,
                    guarded: guarded,
                    final: final,
                    guardFallback: guarded == prepared && rawModel != prepared)
                outcomesByPreparedInput[prepared] = outcome
                log.record(
                    entry: entry, promptID: promptID, prepared: prepared,
                    outcome: outcome, reused: false,
                    seconds: Date().timeIntervalSince(started))
            } catch {
                log.recordError(
                    entry: entry,
                    promptID: promptID,
                    prepared: prepared,
                    error: String(describing: error),
                    seconds: Date().timeIntervalSince(started))
            }
        }
    }
}

private struct RealtimeTextAblationCorpus: Decodable {
    let casesSHA256: String
    let cases: [RealtimeTextAblationCase]
}

private struct RealtimeTextAblationCase: Decodable {
    let id: String
    let feature: String
    let level: String
    let featureStatus: String
    let behaviorClass: String
    let input: String
}

private struct RealtimeTextAblationOutcome {
    let rawModel: String
    let guarded: String
    let final: String
    let guardFallback: Bool
}

private enum RealtimeTextAblationError: Error {
    case malformedProductionSessionUpdate
    case server(String)
    case responseEndedWithoutText
}

private func textAblationFlag(_ path: String) -> String? {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
    else { return nil }
    return value
}

/// Extract the exact prompt assembled by the production session builder. This
/// prevents the control arm from drifting into a hand-maintained prompt copy.
private func productionRealtimeInstructions() throws -> String {
    let update = OpenAIStreamingProvider.buildSessionUpdate(
        sttModel: "gpt-4o-mini-transcribe",
        language: "en",
        context: .empty)
    guard let data = update.data(using: .utf8),
        let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
        let session = object["session"] as? [String: Any],
        let instructions = session["instructions"] as? String,
        !instructions.isEmpty
    else { throw RealtimeTextAblationError.malformedProductionSessionUpdate }
    return instructions
}

private func textOnlySessionUpdate(instructions: String) -> String {
    OpenAIRealtimeWireCodec.jsonString([
        "type": "session.update",
        "session": [
            "type": "realtime",
            "instructions": instructions,
            "output_modalities": ["text"],
            "reasoning": ["effort": "minimal"],
        ],
    ])
}

/// Open one fresh conversation per case so prior model outputs cannot leak
/// into later cases or inflate their token cost.
private func realtimeTextPolish(
    apiKey: String,
    model: String,
    instructions: String,
    transcript: String
) async throws -> String {
    let transport = try OpenAIRealtimeTransportFactory.buildTransport(
        apiKey: apiKey, model: model)
    transport.resume()
    defer { transport.close(.normal) }

    try await transport.send(textOnlySessionUpdate(instructions: instructions))
    try await transport.send(
        OpenAIRealtimeWireCodec.buildPolishRequest(transcript: transcript))
    try await transport.send(OpenAIRealtimeWireCodec.buildResponseCreate())

    var deltas = ""
    var completed = ""
    while true {
        switch OpenAIRealtimeWireCodec.parseEvent(
            try await transport.receiveText())
        {
        case .responseTextDelta(_, _, let delta):
            deltas += delta
        case .responseTextDone(_, _, let text):
            completed = text
        case .responseDone:
            let result = completed.isEmpty ? deltas : completed
            guard !result.isEmpty else {
                throw RealtimeTextAblationError.responseEndedWithoutText
            }
            return result
        case .error(let message):
            throw RealtimeTextAblationError.server(message)
        case .serverError(let details):
            throw RealtimeTextAblationError.server(String(describing: details))
        case .protocolError(let message):
            throw RealtimeTextAblationError.server(message)
        default:
            continue
        }
    }
}

private final class RealtimeTextAblationLog {
    private let handle: FileHandle?

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    func header(
        model: String,
        promptID: String,
        caseCount: Int,
        corpusSHA256: String
    ) {
        emit([
            "recordType": "header",
            "schemaVersion": 1,
            "model": model,
            "promptID": promptID,
            "caseCount": caseCount,
            "corpusSHA256": corpusSHA256,
        ])
    }

    func record(
        entry: RealtimeTextAblationCase,
        promptID: String,
        prepared: String,
        outcome: RealtimeTextAblationOutcome,
        reused: Bool,
        seconds: Double
    ) {
        emit([
            "recordType": "case",
            "id": entry.id,
            "feature": entry.feature,
            "level": entry.level,
            "featureStatus": entry.featureStatus,
            "behaviorClass": entry.behaviorClass,
            "promptID": promptID,
            "input": entry.input,
            "prepared": prepared,
            "rawModel": outcome.rawModel,
            "guarded": outcome.guarded,
            "final": outcome.final,
            "guardFallback": outcome.guardFallback,
            "reused": reused,
            "seconds": (seconds * 1_000).rounded() / 1_000,
        ])
    }

    func recordError(
        entry: RealtimeTextAblationCase,
        promptID: String,
        prepared: String,
        error: String,
        seconds: Double
    ) {
        emit([
            "recordType": "case",
            "id": entry.id,
            "feature": entry.feature,
            "level": entry.level,
            "featureStatus": entry.featureStatus,
            "behaviorClass": entry.behaviorClass,
            "promptID": promptID,
            "input": entry.input,
            "prepared": prepared,
            "error": error,
            "seconds": (seconds * 1_000).rounded() / 1_000,
        ])
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        handle?.seekToEndOfFile()
        handle?.write(data)
        handle?.write(Data("\n".utf8))
    }
}

/// Serialized recorder for Realtime evidence snapshots (mirrors the live
/// harness's recorder; the last snapshot holds the full committed item set).
private actor CloudReplayRecorder {
    private var values: [OpenAIRealtimeCommitSession.EvidenceSnapshot] = []
    func record(_ value: OpenAIRealtimeCommitSession.EvidenceSnapshot) {
        values.append(value)
    }
    func snapshots() -> [OpenAIRealtimeCommitSession.EvidenceSnapshot] { values }
}

/// Append-only line logger writing one record per WAV.
private final class CloudReplayLog {
    private let handle: FileHandle?
    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }
    func log(_ message: String) {
        write(message + "\n")
    }
    func record(wav: String, items: Int, secs: Double, raw: String, out: String) {
        emit([
            "wav": wav, "items": items,
            "secs": (secs * 100).rounded() / 100,
            "raw": raw, "out": out,
        ])
    }
    func recordError(wav: String, error: String) {
        emit(["wav": wav, "error": error])
    }
    private func emit(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.withoutEscapingSlashes]),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let line = "[[CLOUD]] " + json
        write(line + "\n")
        Log.debug(line)
    }
    private func write(_ s: String) {
        guard let handle, let d = s.data(using: .utf8) else { return }
        handle.seekToEndOfFile()
        handle.write(d)
    }
}

private extension Data {
    func replayChunks(maximumByteCount: Int) -> [Data] {
        precondition(maximumByteCount > 0)
        var result: [Data] = []
        var offset = 0
        while offset < count {
            let end = Swift.min(offset + maximumByteCount, count)
            result.append(subdata(in: offset..<end))
            offset = end
        }
        return result
    }
}
