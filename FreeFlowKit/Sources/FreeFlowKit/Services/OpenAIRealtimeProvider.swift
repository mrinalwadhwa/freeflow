import Foundation

/// Stream audio directly to the OpenAI Realtime API for real-time
/// transcription.
///
/// Opens a WebSocket to `wss://api.openai.com/v1/realtime` per dictation
/// session. To avoid paying the handshake cost on every dictation, a
/// fresh connection is pre-opened in the background immediately after a
/// successful session, and adopted by the next `startStreaming` call.
/// A warm backup typically cuts `startStreaming` from ~300 ms to < 5 ms.
///
/// `startStreaming` is non-blocking: it kicks off the connection and
/// session.update in a background task and returns immediately. The
/// `sendAudio` and `finishStreaming` calls await the setup future
/// internally, so the audio forwarding task can begin draining chunks
/// into a buffer as soon as the pipeline starts it. Chunks that arrive
/// before the connection is configured are held and flushed once it is.
///
/// Session protocol:
///
///   1. Open WSS; send `session.update` to configure transcription-only
///      mode, manual commit, and mic-specific noise reduction.
///   2. Forward audio chunks as `input_audio_buffer.append` with
///      base64-encoded 24 kHz PCM (resampled from the 16 kHz capture).
///   3. On finish, send `input_audio_buffer.commit` and read events
///      until `conversation.item.input_audio_transcription.completed`.
///   4. Tear down the connection and polish the transcript locally.
///   5. Pre-open a new backup connection in the background.
public final class OpenAIRealtimeProvider: StreamingDictationProviding, @unchecked Sendable {

    // MARK: - Configuration

    private let apiKeyProvider: @Sendable () -> String
    private let realtimeModel: String
    private let sttModel: String
    private let polishChatClient: OpenAIChatClient?
    private let polishModel: String

    // MARK: - State (guarded by lock)

    private let lock = NSLock()

    /// Active session's WebSocket task, if any.
    private var webSocketTask: URLSessionWebSocketTask?

    /// Active session's URLSession, kept alive with the task.
    private var urlSession: URLSession?

    /// Background task that opens the connection and sends session.update.
    /// `sendAudio` and `finishStreaming` await this future before using
    /// the active task.
    private var setupTask: Task<Void, Error>?

    /// Chunks that arrive before the setup task finishes. Flushed in
    /// order once the connection is ready.
    private var pendingAudio: [Data] = []

    /// Transcript segments accumulated across transcription.completed
    /// events for the current session.
    private var transcriptSegments: [String] = []

    /// AppContext for the current session (captured at startStreaming).
    private var currentContext: AppContext = .empty

    /// Language hint for the current session.
    private var currentLanguage: String?

    // MARK: - Backup connection (warm standby)

    /// Pre-opened connection ready to be adopted by the next session.
    private var backupTask: URLSessionWebSocketTask?
    private var backupSession: URLSession?
    private var backupOpenedAt: Date?
    private var backupOpenTask: Task<Void, Never>?

    /// Maximum age for an idle backup connection. After this, the backup
    /// is discarded on use and a fresh one is opened.
    private let maxBackupAge: TimeInterval = 60

    // MARK: - Init

    public init(
        apiKey: @autoclosure @escaping @Sendable () -> String,
        realtimeModel: String = "gpt-4o-realtime-preview",
        sttModel: String = "gpt-4o-mini-transcribe",
        polishChatClient: OpenAIChatClient?,
        polishModel: String = "gpt-4.1-nano"
    ) {
        self.apiKeyProvider = apiKey
        self.realtimeModel = realtimeModel
        self.sttModel = sttModel
        self.polishChatClient = polishChatClient
        self.polishModel = polishModel
    }

    deinit {
        backupOpenTask?.cancel()
        backupTask?.cancel(with: .normalClosure, reason: nil)
        backupSession?.invalidateAndCancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: - StreamingDictationProviding

    public func startStreaming(
        context: AppContext, language: String?, micProximity: MicProximity
    ) async throws {
        try Task.checkCancellation()

        // Reset per-session state.
        lock.withLock {
            self.currentContext = context
            self.currentLanguage = language
            self.pendingAudio.removeAll()
            self.transcriptSegments.removeAll()
        }

        // Try to adopt a fresh backup connection. If the backup is missing
        // or stale, open a new one. Either way, store the setup future so
        // sendAudio and finishStreaming can await it.
        let adopted = adoptBackupIfFresh()

        let freshModel = realtimeModel
        let freshAPIKey = apiKeyProvider()
        let freshSTTModel = sttModel

        setupTask = Task { [weak self] in
            try Task.checkCancellation()
            guard let self else { return }

            let task: URLSessionWebSocketTask
            let session: URLSession

            if let adopted {
                task = adopted.task
                session = adopted.session
            } else {
                let (newTask, newSession) = try Self.buildWebSocketTask(
                    apiKey: freshAPIKey, model: freshModel)
                newTask.resume()
                task = newTask
                session = newSession
            }

            // If cancelled after building but before publishing, clean
            // up the locally held task/session and bail. Without this,
            // cancelStreaming running between these lines could leave a
            // stale task in webSocketTask for the next session.
            if Task.isCancelled {
                task.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
                throw CancellationError()
            }

            // Publish the task immediately so tearDown can reach it even
            // if session.update fails.
            self.lock.withLock {
                self.webSocketTask = task
                self.urlSession = session
            }

            // Send session.update to configure transcription-only mode.
            let update = Self.buildSessionUpdate(
                sttModel: freshSTTModel,
                language: language,
                micProximity: micProximity)
            try await task.send(.string(update))
        }
    }

    public func sendAudio(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }

        // Resample from 16 kHz capture rate to 24 kHz required by the
        // Realtime API.
        let pcm24k = AudioResampler.resample16kTo24k(pcmData)

        // Await the setup future. If the connection is still being
        // established, buffer the chunk and return — it will be flushed
        // on the next successful setup.
        do {
            try await awaitSetup()
        } catch {
            lock.withLock {
                self.pendingAudio.append(pcm24k)
            }
            throw error
        }

        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw DictationError.networkError("No active WebSocket")
        }

        // Flush any buffered chunks first to preserve order.
        let buffered: [Data] = lock.withLock {
            let b = self.pendingAudio
            self.pendingAudio.removeAll()
            return b
        }
        for chunk in buffered {
            let msg = Self.buildAudioAppend(pcm24k: chunk)
            try await task.send(.string(msg))
        }
        let msg = Self.buildAudioAppend(pcm24k: pcm24k)
        try await task.send(.string(msg))
    }

    public func finishStreaming() async throws -> String {
        try await awaitSetup()

        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw DictationError.networkError("No active WebSocket")
        }

        // Flush any remaining buffered audio before committing.
        let buffered: [Data] = lock.withLock {
            let b = self.pendingAudio
            self.pendingAudio.removeAll()
            return b
        }
        for chunk in buffered {
            let msg = Self.buildAudioAppend(pcm24k: chunk)
            try await task.send(.string(msg))
        }

        // Commit the audio buffer so the server begins transcription.
        try await task.send(.string(Self.buildCommit()))

        // Read events until we see transcription.completed or an error.
        let transcript: String
        do {
            transcript = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await Self.readTranscriptUntilCompleted(on: task)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)  // 10s
                    // Force-cancel the WebSocket so receive() throws.
                    task.cancel(with: .abnormalClosure, reason: nil)
                    throw DictationError.networkError(
                        "Timed out waiting for transcript")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            await tearDown()
            throw error
        }

        // Tear down the current session's connection and spawn a new
        // backup in the background for the next session.
        await tearDown()
        warmBackup()

        // Polish the raw transcript locally.
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        return await polish(trimmed)
    }

    public func cancelStreaming() async {
        setupTask?.cancel()
        await tearDown()
    }

    public func dictateViaBackup(
        audio: Data, context: AppContext, language: String?
    ) async throws -> String {
        // Open a dedicated connection for this one-shot request. Do not
        // consume the warm backup because the pipeline may call this in
        // parallel with the next session's startStreaming.
        let (task, session) = try Self.buildWebSocketTask(
            apiKey: apiKeyProvider(), model: realtimeModel)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        // Configure the session.
        let update = Self.buildSessionUpdate(
            sttModel: sttModel,
            language: language,
            micProximity: .nearField)
        try await task.send(.string(update))

        // Send the audio (extract PCM from WAV, resample, chunk, append).
        let pcm16k = Self.extractPCM(fromWAV: audio)
        let pcm24k = AudioResampler.resample16kTo24k(pcm16k)
        let chunkBytes = 24000 * 2 / 4  // ~250 ms at 24 kHz, 16-bit
        var offset = 0
        while offset < pcm24k.count {
            let end = min(offset + chunkBytes, pcm24k.count)
            let chunk = pcm24k.subdata(in: offset..<end)
            let msg = Self.buildAudioAppend(pcm24k: chunk)
            try await task.send(.string(msg))
            offset = end
        }

        // Commit and wait for the transcript.
        try await task.send(.string(Self.buildCommit()))
        let transcript = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await Self.readTranscriptUntilCompleted(on: task)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                task.cancel(with: .abnormalClosure, reason: nil)
                throw DictationError.networkError(
                    "Timed out waiting for transcript")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        // Store context for polish.
        lock.withLock {
            self.currentContext = context
            self.currentLanguage = language
        }
        return await polish(trimmed)
    }

    /// Disconnect and release all connections. Call at app shutdown.
    public func disconnect() async {
        setupTask?.cancel()
        backupOpenTask?.cancel()
        await tearDown()
        await discardBackup()
    }

    // MARK: - Setup future

    /// Await the setup task, returning when the connection is ready and
    /// session.update has been sent. Throws any setup error.
    private func awaitSetup() async throws {
        guard let task = setupTask else {
            throw DictationError.networkError("No active streaming session")
        }
        try await task.value
    }

    // MARK: - Backup connection

    /// Spawn a background task that opens a new connection for the next
    /// session. No-op if one is already in flight or ready.
    private func warmBackup() {
        let shouldStart: Bool = lock.withLock {
            if self.backupTask != nil || self.backupOpenTask != nil {
                return false
            }
            return true
        }
        guard shouldStart else { return }

        let bApiKey = apiKeyProvider()
        let bModel = realtimeModel

        let openTask = Task { [weak self] in
            do {
                let (task, session) = try Self.buildWebSocketTask(
                    apiKey: bApiKey, model: bModel)
                task.resume()
                // Don't send any messages on the backup — it stays idle
                // until adopted by a future startStreaming call.
                guard !Task.isCancelled else {
                    task.cancel(with: .normalClosure, reason: nil)
                    session.invalidateAndCancel()
                    return
                }
                self?.lock.withLock {
                    self?.backupTask = task
                    self?.backupSession = session
                    self?.backupOpenedAt = Date()
                    self?.backupOpenTask = nil
                }
            } catch {
                self?.lock.withLock {
                    self?.backupOpenTask = nil
                }
            }
        }

        lock.withLock {
            self.backupOpenTask = openTask
        }
    }

    /// Attempt to adopt a fresh backup as the active connection.
    /// Returns the task and session if adopted; nil otherwise.
    ///
    /// A stale backup (older than `maxBackupAge`) is discarded instead
    /// of adopted.
    private func adoptBackupIfFresh() -> (task: URLSessionWebSocketTask, session: URLSession)? {
        let result: (URLSessionWebSocketTask, URLSession)? = lock.withLock {
            guard let task = self.backupTask,
                let session = self.backupSession,
                let openedAt = self.backupOpenedAt
            else {
                return nil
            }
            let age = Date().timeIntervalSince(openedAt)
            if age > self.maxBackupAge {
                // Stale: caller will discard.
                return nil
            }
            self.backupTask = nil
            self.backupSession = nil
            self.backupOpenedAt = nil
            return (task, session)
        }

        if let result {
            return (task: result.0, session: result.1)
        }

        // If we got here and a backup exists but is stale, tear it down
        // synchronously before the caller opens a fresh connection.
        Task { await self.discardBackup() }
        return nil
    }

    /// Tear down and forget any pre-opened backup connection.
    private func discardBackup() async {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.backupTask
            let s = self.backupSession
            self.backupTask = nil
            self.backupSession = nil
            self.backupOpenedAt = nil
            return (t, s)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Connection lifecycle

    /// Build a fresh URLSessionWebSocketTask for the OpenAI Realtime API.
    static func buildWebSocketTask(
        apiKey: String, model: String
    ) throws -> (URLSessionWebSocketTask, URLSession) {
        let url = buildWebSocketURL(model: model)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        return (session.webSocketTask(with: request), session)
    }

    /// Tear down the active session's WebSocket and URLSession.
    private func tearDown() async {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.webSocketTask
            let s = self.urlSession
            self.webSocketTask = nil
            self.urlSession = nil
            self.pendingAudio.removeAll()
            self.transcriptSegments.removeAll()
            return (t, s)
        }
        setupTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Message builders (testable pure functions)

    /// Build the Realtime API WebSocket URL for the given model.
    static func buildWebSocketURL(model: String) -> URL {
        var components = URLComponents(
            string: "wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url!
    }

    /// Build the `session.update` message to configure transcription-only
    /// mode with manual commit and mic-specific noise reduction.
    static func buildSessionUpdate(
        sttModel: String,
        language: String?,
        micProximity: MicProximity
    ) -> String {
        var transcription: [String: Any] = ["model": sttModel]
        if let language {
            transcription["language"] = language
        }

        let noiseReductionType: String
        switch micProximity {
        case .nearField: noiseReductionType = "near_field"
        case .farField: noiseReductionType = "far_field"
        }

        let session: [String: Any] = [
            "modalities": ["text", "audio"],
            "input_audio_format": "pcm16",
            "input_audio_transcription": transcription,
            // NSNull serializes as JSON null, which disables server VAD
            // so the client controls when audio ends via commit.
            "turn_detection": NSNull(),
            "input_audio_noise_reduction": [
                "type": noiseReductionType
            ],
        ]

        return jsonString([
            "type": "session.update",
            "session": session,
        ])
    }

    /// Build an `input_audio_buffer.append` message wrapping base64 PCM.
    static func buildAudioAppend(pcm24k: Data) -> String {
        jsonString([
            "type": "input_audio_buffer.append",
            "audio": pcm24k.base64EncodedString(),
        ])
    }

    /// Build the `input_audio_buffer.commit` message.
    static func buildCommit() -> String {
        jsonString(["type": "input_audio_buffer.commit"])
    }

    // MARK: - Event parsing (testable pure function)

    enum ParsedEvent: Equatable {
        case transcriptionDelta(String)
        case transcriptionCompleted(String)
        case error(String)
        case other
    }

    static func parseEvent(_ text: String) -> ParsedEvent {
        guard
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else {
            return .other
        }

        switch type {
        case "conversation.item.input_audio_transcription.completed":
            let transcript = obj["transcript"] as? String ?? ""
            return .transcriptionCompleted(transcript)
        case "conversation.item.input_audio_transcription.delta":
            let delta = obj["delta"] as? String ?? ""
            return .transcriptionDelta(delta)
        case "error":
            if let error = obj["error"] as? [String: Any],
                let message = error["message"] as? String
            {
                return .error(message)
            }
            return .error("unknown error")
        default:
            return .other
        }
    }

    // MARK: - WebSocket receive

    /// Read events on a task until the first `transcription.completed`
    /// arrives or an error is received. Other event types are discarded.
    static func readTranscriptUntilCompleted(
        on task: URLSessionWebSocketTask
    ) async throws -> String {
        var segments: [String] = []
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw DictationError.networkError(
                    "WebSocket receive failed: \(error.localizedDescription)")
            }

            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
            @unknown default: continue
            }

            switch parseEvent(text) {
            case .transcriptionCompleted(let transcript):
                if !transcript.isEmpty {
                    segments.append(transcript)
                }
                return segments.joined(separator: " ")
            case .error(let message):
                throw DictationError.networkError(
                    "Realtime API error: \(message)")
            case .transcriptionDelta, .other:
                continue
            }
        }
    }

    // MARK: - Polishing

    private func polish(_ raw: String) async -> String {
        let substituted = PolishPipeline.substituteDictatedPunctuation(raw)
        let stripped = PolishPipeline.stripKeepTags(substituted)

        if PolishPipeline.isClean(stripped) {
            return stripped
        }

        guard let polishChatClient else {
            return PolishPipeline.normalizeFormatting(stripped)
        }

        let context: AppContext = lock.withLock { self.currentContext }
        let userPrompt = PolishPipeline.buildUserPrompt(
            substituted, context: context)
        do {
            let polished = try await polishChatClient.complete(
                model: polishModel,
                systemPrompt: PolishPipeline.systemPromptEnglish,
                userPrompt: userPrompt)
            if polished.isEmpty {
                return PolishPipeline.normalizeFormatting(stripped)
            }
            return PolishPipeline.normalizeFormatting(
                PolishPipeline.stripKeepTags(polished))
        } catch {
            return PolishPipeline.normalizeFormatting(stripped)
        }
    }

    // MARK: - WAV helpers

    /// Extract raw PCM bytes from a WAV file by stripping the 44-byte
    /// RIFF header produced by `WAVEncoder`.
    static func extractPCM(fromWAV wav: Data) -> Data {
        guard wav.count > 44 else { return Data() }
        return wav.subdata(in: 44..<wav.count)
    }

    // MARK: - JSON helper

    private static func jsonString(_ object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
