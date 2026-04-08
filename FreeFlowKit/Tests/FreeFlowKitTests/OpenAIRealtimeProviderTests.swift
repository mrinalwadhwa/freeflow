import Foundation
import Testing

@testable import FreeFlowKit

// ---------------------------------------------------------------------------
// Tests for the OpenAI Realtime API streaming dictation provider.
//
// Message-construction tests exercise the pure functions that build
// session.update, input_audio_buffer.append, and commit messages. Live
// integration tests (gated by FREEFLOW_TEST_OPENAI=1) open a real
// WebSocket to api.openai.com and run through the full streaming cycle.
// ---------------------------------------------------------------------------

// MARK: - Helpers

/// Build a short WAV containing a 1 kHz tone at 16 kHz mono.
private func toneWAV(seconds: Double = 1.0, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    var pcm = Data(capacity: sampleCount * 2)
    for i in 0..<sampleCount {
        let t = Double(i) / Double(sampleRate)
        let value = Int16(3000.0 * sin(2.0 * .pi * 1000.0 * t))
        pcm.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
    return pcm  // Raw PCM, not WAV — matches what AudioCaptureProvider emits.
}

/// Build a silent 16-bit mono PCM buffer at 16 kHz.
private func silentPCM(seconds: Double = 0.5, sampleRate: Int = 16000) -> Data {
    let sampleCount = Int(seconds * Double(sampleRate))
    return Data(count: sampleCount * 2)
}

// MARK: - Message Construction

@Suite("OpenAIRealtimeProvider – message construction")
struct OpenAIRealtimeMessageTests {

    @Test("session.update has required transcription fields")
    func sessionUpdate() throws {
        let json = OpenAIRealtimeProvider.buildSessionUpdate(
            sttModel: "gpt-4o-mini-transcribe",
            language: "en",
            micProximity: .nearField)
        let data = json.data(using: .utf8)!
        let obj = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["type"] as? String == "session.update")

        let session = try #require(obj["session"] as? [String: Any])
        #expect((session["modalities"] as? [String])?.contains("text") == true)
        #expect((session["modalities"] as? [String])?.contains("audio") == true)
        #expect(session["input_audio_format"] as? String == "pcm16")

        let transcription = try #require(
            session["input_audio_transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        #expect(transcription["language"] as? String == "en")

        // turn_detection must be NSNull so the server does not auto-commit.
        #expect(session["turn_detection"] is NSNull)

        let noiseReduction = try #require(
            session["input_audio_noise_reduction"] as? [String: Any])
        #expect(noiseReduction["type"] as? String == "near_field")
    }

    @Test("session.update omits language when nil")
    func sessionUpdateNoLanguage() throws {
        let json = OpenAIRealtimeProvider.buildSessionUpdate(
            sttModel: "gpt-4o-mini-transcribe",
            language: nil,
            micProximity: .farField)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let transcription = session["input_audio_transcription"] as! [String: Any]
        #expect(transcription["language"] == nil)
    }

    @Test("session.update uses far_field for far-field mic")
    func sessionUpdateFarField() throws {
        let json = OpenAIRealtimeProvider.buildSessionUpdate(
            sttModel: "m", language: nil, micProximity: .farField)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let noiseReduction = session["input_audio_noise_reduction"] as! [String: Any]
        #expect(noiseReduction["type"] as? String == "far_field")
    }

    @Test("audio append message contains base64 audio")
    func audioAppend() throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let json = OpenAIRealtimeProvider.buildAudioAppend(pcm24k: pcm)
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["type"] as? String == "input_audio_buffer.append")
        let audio = obj["audio"] as! String
        // Verify it decodes back to the original PCM.
        let decoded = try #require(Data(base64Encoded: audio))
        #expect(decoded == pcm)
    }

    @Test("commit message has correct type")
    func commit() throws {
        let json = OpenAIRealtimeProvider.buildCommit()
        let obj = try JSONSerialization.jsonObject(
            with: json.data(using: .utf8)!) as! [String: Any]
        #expect(obj["type"] as? String == "input_audio_buffer.commit")
    }

    @Test("websocket URL has model parameter")
    func websocketURL() {
        let url = OpenAIRealtimeProvider.buildWebSocketURL(model: "gpt-4o-realtime-preview")
        #expect(url.absoluteString.hasPrefix("wss://api.openai.com/v1/realtime"))
        #expect(url.absoluteString.contains("model=gpt-4o-realtime-preview"))
    }

    @Test("websocket URL scheme is wss")
    func websocketURLScheme() {
        let url = OpenAIRealtimeProvider.buildWebSocketURL(model: "m")
        #expect(url.scheme == "wss")
    }
}

// MARK: - Event Parsing

@Suite("OpenAIRealtimeProvider – event parsing")
struct OpenAIRealtimeEventTests {

    @Test("parses transcription.completed event")
    func transcriptionCompleted() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.completed",
             "transcript":"hello world"}
            """
        let parsed = OpenAIRealtimeProvider.parseEvent(event)
        if case .transcriptionCompleted(let transcript) = parsed {
            #expect(transcript == "hello world")
        } else {
            Issue.record("expected transcriptionCompleted, got \(parsed)")
        }
    }

    @Test("parses transcription.delta event")
    func transcriptionDelta() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.delta",
             "delta":"hel"}
            """
        let parsed = OpenAIRealtimeProvider.parseEvent(event)
        if case .transcriptionDelta(let delta) = parsed {
            #expect(delta == "hel")
        } else {
            Issue.record("expected transcriptionDelta, got \(parsed)")
        }
    }

    @Test("parses error event")
    func errorEvent() {
        let event = """
            {"type":"error","error":{"message":"bad audio","code":"invalid_audio"}}
            """
        let parsed = OpenAIRealtimeProvider.parseEvent(event)
        if case .error(let message) = parsed {
            #expect(message.contains("bad audio"))
        } else {
            Issue.record("expected error, got \(parsed)")
        }
    }

    @Test("ignores unknown event types")
    func ignoresUnknown() {
        let event = #"{"type":"session.created","session":{}}"#
        let parsed = OpenAIRealtimeProvider.parseEvent(event)
        if case .other = parsed {
            // Expected.
        } else {
            Issue.record("expected other, got \(parsed)")
        }
    }

    @Test("returns other for malformed JSON")
    func malformedJSON() {
        let parsed = OpenAIRealtimeProvider.parseEvent("not json")
        if case .other = parsed {
            // Expected.
        } else {
            Issue.record("expected other, got \(parsed)")
        }
    }

    @Test("transcription.completed with empty transcript")
    func emptyTranscript() {
        let event = """
            {"type":"conversation.item.input_audio_transcription.completed",
             "transcript":""}
            """
        let parsed = OpenAIRealtimeProvider.parseEvent(event)
        if case .transcriptionCompleted(let transcript) = parsed {
            #expect(transcript == "")
        } else {
            Issue.record("expected transcriptionCompleted, got \(parsed)")
        }
    }
}

// MARK: - Live Integration (gated)

@Suite(
    "OpenAIRealtimeProvider – live",
    .disabled(if: ProcessInfo.processInfo.environment["FREEFLOW_TEST_OPENAI"] != "1"))
struct OpenAIRealtimeLiveTests {

    private var apiKey: String {
        ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }

    @Test("live: open, send silent audio, commit, close")
    func liveSilentSession() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIRealtimeProvider(
            apiKey: apiKey, polishChatClient: nil)
        try await provider.startStreaming(
            context: AppContext.empty,
            language: "en",
            micProximity: .nearField)
        // Feed half a second of silent audio.
        let pcm = silentPCM(seconds: 0.5)
        try await provider.sendAudio(pcm)
        // finishStreaming commits and returns the transcript (likely empty).
        _ = try await provider.finishStreaming()
        await provider.cancelStreaming()
    }

    @Test("live: tone signal returns a response")
    func liveToneSession() async throws {
        guard !apiKey.isEmpty else {
            Issue.record("OPENAI_API_KEY not set")
            return
        }
        let provider = OpenAIRealtimeProvider(
            apiKey: apiKey, polishChatClient: nil)
        try await provider.startStreaming(
            context: AppContext.empty,
            language: "en",
            micProximity: .farField)
        let pcm = toneWAV(seconds: 1.0)
        try await provider.sendAudio(pcm)
        _ = try await provider.finishStreaming()
        await provider.cancelStreaming()
    }
}
