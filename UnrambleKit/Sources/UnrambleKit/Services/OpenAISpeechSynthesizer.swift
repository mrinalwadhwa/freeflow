import Foundation

/// Speaks read-aloud scripts through OpenAI's streaming speech API.
///
/// Cloud mode's voice: the machines cloud mode serves cannot run the
/// local model, and their users have already chosen cloud processing
/// over locality. Long scripts synthesize in sentence chunks; each
/// chunk's PCM streams into playback as it generates, so first audio
/// arrives without waiting for the whole script. A failure before any
/// audio has played falls back to the system voice so a read session
/// never ends silently on a network error.
public final class OpenAISpeechSynthesizer: SpeechSynthesizing,
    @unchecked Sendable
{

    /// One second of 24 kHz mono 16-bit PCM is 48000 bytes; scheduling
    /// roughly five times a second keeps latency and call overhead low.
    private static let scheduleThresholdBytes = 9600

    /// The generative voice samples pronunciations, so names it does not
    /// know vary between runs; steady guidance is the cloud analog of
    /// the local voice's phoneme overrides.
    public static let defaultInstructions =
        "Read the text verbatim in a calm, clear voice. "
        + "Pronounce the name Mrinal Wadhwa with its correct native "
        + "pronunciation, the same way every time."

    private let apiKeyProvider: @Sendable () -> String
    private let model: String
    private let voice: String
    private let instructions: String
    private let endpoint: URL
    private let session: URLSession
    private let fallback: (any SpeechSynthesizing)?

    private let lock = NSLock()
    private var speechTask: Task<Void, Never>?
    private var activePlayback: PCMChunkPlayback?

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        model: String = "gpt-4o-mini-tts",
        voice: String = "nova",
        instructions: String = OpenAISpeechSynthesizer.defaultInstructions,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/speech")!,
        session: URLSession? = nil,
        fallback: (any SpeechSynthesizing)? = nil
    ) {
        self.apiKeyProvider = apiKey
        self.model = model
        self.voice = voice
        self.instructions = instructions
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            NetworkGuard.apply(to: configuration)
            self.session = URLSession(configuration: configuration)
        }
        self.fallback = fallback
    }

    public func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopSpeaking()

        let task = Task { await self.run(text: trimmed) }
        lock.withLock { speechTask = task }
        await task.value
        lock.withLock {
            if speechTask == task {
                speechTask = nil
            }
        }
    }

    public func stopSpeaking() {
        let (task, playback): (Task<Void, Never>?, PCMChunkPlayback?) =
            lock.withLock {
                let stoppedTask = speechTask
                speechTask = nil
                let stoppedPlayback = activePlayback
                activePlayback = nil
                return (stoppedTask, stoppedPlayback)
            }
        task?.cancel()
        playback?.stop()
        fallback?.stopSpeaking()
    }

    // MARK: - Session

    private func run(text: String) async {
        let playback = PCMChunkPlayback(sampleRate: 24_000)
        lock.withLock { activePlayback = playback }
        defer {
            lock.withLock {
                if activePlayback === playback {
                    activePlayback = nil
                }
            }
        }

        var scheduledAnyAudio = false
        do {
            // Large chunks keep request overhead low; streaming hides the
            // per-chunk generation time.
            for chunk in KokoroSpeechChunker.chunks(
                from: text, maximumLength: 3000)
            {
                try Task.checkCancellation()
                try await stream(chunk: chunk, into: playback) {
                    scheduledAnyAudio = true
                }
            }
            await playback.drain()
        } catch is CancellationError {
            // Stopped; playback was silenced by stopSpeaking.
        } catch {
            Log.debug("[OpenAITTS] Speech failed: \(error)")
            playback.stop()
            if !scheduledAnyAudio, let fallback, !Task.isCancelled {
                await fallback.speak(text)
            }
        }
    }

    private func stream(
        chunk: String,
        into playback: PCMChunkPlayback,
        onAudio: () -> Void
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKeyProvider())", forHTTPHeaderField: "Authorization")
        var body: [String: String] = [
            "model": model,
            "voice": voice,
            "input": chunk,
            "response_format": "pcm",
        ]
        if !instructions.isEmpty {
            body["instructions"] = instructions
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw OpenAISpeechError.requestFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        var buffer = Data()
        buffer.reserveCapacity(Self.scheduleThresholdBytes * 2)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.scheduleThresholdBytes {
                try Task.checkCancellation()
                let remainder = buffer.count % 2
                let samples = Self.floats(
                    fromPCM16LE: buffer.prefix(buffer.count - remainder))
                buffer = remainder == 0 ? Data() : buffer.suffix(remainder)
                if !samples.isEmpty {
                    try playback.schedule(samples: samples)
                    onAudio()
                }
            }
        }
        let samples = Self.floats(
            fromPCM16LE: buffer.prefix(buffer.count - buffer.count % 2))
        if !samples.isEmpty {
            try playback.schedule(samples: samples)
            onAudio()
        }
    }

    /// Convert little-endian 16-bit PCM to the float samples playback
    /// schedules.
    static func floats(fromPCM16LE data: Data) -> [Float] {
        let sampleCount = data.count / 2
        var samples = [Float](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { bytes in
            for index in 0..<sampleCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1])
                let value = Int16(bitPattern: (high << 8) | low)
                samples[index] = Float(value) / 32768.0
            }
        }
        return samples
    }

    deinit {
        speechTask?.cancel()
        activePlayback?.stop()
    }
}

enum OpenAISpeechError: Error {
    case requestFailed(Int)
}
