import Foundation

/// Stream audio to the VoiceService `/stream` WebSocket endpoint for
/// real-time transcription via the OpenAI Realtime API.
///
/// The provider maintains a persistent WebSocket connection across
/// dictation sessions. Each `startStreaming` / `sendAudio` /
/// `finishStreaming` cycle runs as one dictation session over the
/// same connection. A background keepalive sends "ping" messages
/// during idle periods, and the connection is automatically
/// re-established if it drops between sessions.
///
/// Protocol (client -> server), per session:
///   1. `{"type":"start","context":{...},"language":"en"}`
///   2. `{"type":"audio","audio":"<base64 PCM16 16kHz>"}`  (repeated)
///   3. `{"type":"stop"}`
///
/// Protocol (server -> client):
///   - `{"type":"transcript_delta","delta":"..."}`
///   - `{"type":"transcript_done","text":"...","raw":"..."}`
///   - `{"type":"error","error":"..."}`
///   - `{"type":"pong"}`
///
/// Between sessions the client sends `{"type":"ping"}` every 15 s
/// and expects `{"type":"pong"}` back from the server.
public final class VoiceServiceStreamingProvider: StreamingDictationProviding, @unchecked Sendable {

    private let baseURL: String
    private let apiKey: String

    /// Protects mutable session state across concurrent callers.
    private let lock = NSLock()

    /// The persistent WebSocket task, reused across dictation sessions.
    private var webSocketTask: URLSessionWebSocketTask?

    /// The URLSession backing the WebSocket. Kept alive with the task.
    private var urlSession: URLSession?

    /// Background keepalive task that sends pings during idle periods.
    private var keepaliveTask: Task<Void, Never>?

    /// Whether a dictation session is currently active (between
    /// `startStreaming` and `finishStreaming`/`cancelStreaming`).
    private var sessionActive: Bool = false

    /// How often to send a keepalive ping when idle (in seconds).
    private let keepaliveInterval: TimeInterval = 15.0

    /// Number of completed sessions on the current connection.
    private var sessionCount: Int = 0

    /// Force a fresh connection after this many sessions to avoid
    /// accumulated state degradation (stale buffers, server-side GC
    /// pressure, etc.). Observed in testing: streaming setup starts
    /// timing out after ~8-12 sessions on the same connection.
    private let maxSessionsPerConnection: Int = 8

    /// When the current WebSocket connection was established.
    private var connectionEstablishedAt: Date?

    /// Force a fresh connection after this duration even if sessions
    /// are under the limit. Long-lived idle connections can go stale
    /// despite keepalive pings (load balancer timeouts, TCP RSTs).
    private let maxConnectionAge: TimeInterval = 300  // 5 minutes

    /// Create a provider with explicit configuration.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the VoiceService (e.g. "https://...cluster.autonomy.computer").
    ///   - apiKey: Bearer token for authentication.
    public init(baseURL: String? = nil, apiKey: String? = nil) {
        self.baseURL = baseURL ?? ServiceConfig.baseURL
        self.apiKey = apiKey ?? ServiceConfig.apiKey
    }

    // MARK: - StreamingDictationProviding

    public func startStreaming(context: AppContext, language: String?) async throws {
        // Bail out if the calling task was cancelled (e.g. timeout).
        try Task.checkCancellation()

        // Ensure we have a live connection, reconnecting if needed.
        try await ensureConnected()

        lock.withLock {
            sessionActive = true
        }

        // Pause keepalive pings during the active session — the audio
        // traffic keeps the connection alive.
        stopKeepalive()

        // Send the start message with context and language.
        let startMessage = buildStartMessage(context: context, language: language)
        try await send(json: startMessage)

        Log.debug("[StreamingProvider] Session started (persistent)")
    }

    public func sendAudio(_ pcmData: Data) async throws {
        guard !pcmData.isEmpty else { return }

        let base64Audio = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "type": "audio",
            "audio": base64Audio,
        ]

        try await send(json: message)
    }

    public func finishStreaming() async throws -> String {
        // Send the stop signal.
        try await send(json: ["type": "stop"])

        Log.debug("[StreamingProvider] Stop sent, waiting for transcript")

        // Read messages until we receive transcript_done or error.
        // Timeout after 10 seconds to avoid hanging forever if the
        // server never sends a result (e.g. WebSocket silently died).
        // On timeout the pipeline falls back to batch mode using the
        // captured audio buffer.
        //
        // URLSessionWebSocketTask.receive() does NOT respond to Swift
        // structured concurrency cancellation — it keeps blocking even
        // after the task is cancelled. To actually unblock it, we must
        // cancel the WebSocket task itself, which causes receive() to
        // throw immediately.
        let result: String
        do {
            result = try await withTranscriptTimeout(seconds: 10) {
                try await self.waitForResult()
            }
        } catch {
            Log.debug("[StreamingProvider] waitForResult failed: \(error)")
            // The connection may have broken during this session.
            // Mark it dead so the next session reconnects.
            lock.withLock {
                sessionActive = false
            }
            await tearDownConnection()
            throw error
        }

        let count: Int = lock.withLock {
            sessionActive = false
            sessionCount += 1
            return sessionCount
        }

        Log.debug("[StreamingProvider] Session \(count) finished on this connection")

        // If we have hit the session limit, proactively tear down so
        // the next dictation starts with a fresh connection. This
        // avoids the gradual degradation observed in long-running use.
        if count >= maxSessionsPerConnection {
            Log.debug(
                "[StreamingProvider] Reached \(maxSessionsPerConnection) sessions, "
                    + "proactively reconnecting"
            )
            stopKeepalive()
            await tearDownConnection()
        } else {
            // Resume keepalive pings now that the session is done.
            startKeepalive()
        }

        return result
    }

    public func cancelStreaming() async {
        let wasActive: Bool = lock.withLock {
            let active = sessionActive
            sessionActive = false
            return active
        }

        if wasActive {
            Log.debug("[StreamingProvider] Session cancelled")
        }

        // On cancel, tear down the connection entirely. The server
        // expects stop→transcript_done flow; a mid-session cancel
        // leaves the server-side session in an undefined state, so
        // a fresh connection is needed next time.
        stopKeepalive()
        await tearDownConnection()
    }

    /// Disconnect the persistent WebSocket. Call when the provider
    /// is no longer needed (e.g. app shutdown).
    public func disconnect() async {
        stopKeepalive()
        await tearDownConnection()
        Log.debug("[StreamingProvider] Disconnected")
    }

    // MARK: - Connection Management

    /// Ensure there is a live WebSocket connection, creating one if needed.
    ///
    /// Proactively tears down connections that have exceeded the session
    /// limit or age limit before checking liveness, so the next session
    /// always starts on a healthy connection.
    private func ensureConnected() async throws {
        // Bail out early if the calling task has been cancelled (e.g. the
        // streaming-setup timeout fired and cancelled the detached task).
        try Task.checkCancellation()

        // Check whether the existing connection should be recycled due
        // to age, even if it appears healthy. Long-lived connections can
        // degrade silently (load balancer idle timeouts, TCP RSTs that
        // URLSession absorbs internally).
        let shouldRecycle: Bool = lock.withLock {
            if let established = connectionEstablishedAt,
                Date().timeIntervalSince(established) > maxConnectionAge
            {
                return true
            }
            return false
        }

        if shouldRecycle {
            Log.debug(
                "[StreamingProvider] Connection exceeded max age (\(Int(maxConnectionAge))s), recycling"
            )
            stopKeepalive()
            await tearDownConnection()
        }

        let existing: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }

        if let task = existing {
            // Check if the task is still in a usable state.
            switch task.state {
            case .running:
                // Verify liveness with a protocol-level ping.
                // Timeout after 3s — sendPing can hang indefinitely when
                // the WebSocket is in a broken state (e.g. half-closed TCP).
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await withCheckedThrowingContinuation {
                                (cont: CheckedContinuation<Void, Error>) in
                                // Guard against double-resume: URLSessionWebSocketTask
                                // can invoke the sendPing completion more than once when
                                // the connection is aborting while a ping is in flight.
                                let pingLock = NSLock()
                                var resumed = false
                                task.sendPing { error in
                                    let alreadyResumed = pingLock.withLock {
                                        let was = resumed
                                        resumed = true
                                        return was
                                    }
                                    guard !alreadyResumed else { return }
                                    if let error {
                                        cont.resume(throwing: error)
                                    } else {
                                        cont.resume()
                                    }
                                }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 3_000_000_000)
                            throw CancellationError()
                        }
                        // Wait for whichever finishes first.
                        try await group.next()
                        group.cancelAll()
                    }
                    return  // Connection is alive.
                } catch {
                    Log.debug(
                        "[StreamingProvider] Existing connection failed ping (or timed out), reconnecting"
                    )
                    await tearDownConnection()
                }
            default:
                Log.debug("[StreamingProvider] Existing connection not running, reconnecting")
                await tearDownConnection()
            }
        }

        // Check cancellation again after teardown — the timeout may have
        // fired while we were tearing down the old connection.
        try Task.checkCancellation()

        // Build and start a new connection.
        let task = try buildWebSocketTask()

        lock.withLock {
            self.webSocketTask = task
            self.sessionCount = 0
            self.connectionEstablishedAt = Date()
        }

        task.resume()

        // Start keepalive for the new connection (will be paused once
        // a dictation session starts).
        startKeepalive()

        Log.debug("[StreamingProvider] Connected (new connection)")
    }

    /// Build a URLSessionWebSocketTask for the /stream endpoint.
    ///
    /// Always creates a fresh URLSession so that a prior `tearDownConnection()`
    /// (which calls `invalidateAndCancel()`) cannot affect the new task.
    private func buildWebSocketTask() throws -> URLSessionWebSocketTask {
        // Invalidate any leftover session first to avoid leaking sessions
        // if buildWebSocketTask is called without a prior teardown.
        let oldSession: URLSession? = lock.withLock {
            let s = self.urlSession
            self.urlSession = nil
            return s
        }
        oldSession?.invalidateAndCancel()

        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Convert HTTP(S) URL to WS(S).
        var wsBase = trimmed
        if wsBase.hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        }

        // Append the token as a query parameter since URLSessionWebSocketTask
        // does not support custom headers on the initial handshake.
        guard let url = URL(string: wsBase + "/stream?token=" + apiKey) else {
            throw DictationError.networkError("Invalid base URL: " + baseURL)
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300  // Long timeout for persistent connection.
        let session = URLSession(configuration: config)

        lock.withLock {
            self.urlSession = session
        }

        return session.webSocketTask(with: url)
    }

    /// Tear down the WebSocket and URLSession, clearing all references.
    private func tearDownConnection() async {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.webSocketTask
            let s = self.urlSession
            self.webSocketTask = nil
            self.urlSession = nil
            self.connectionEstablishedAt = nil
            self.sessionCount = 0
            return (t, s)
        }

        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    // MARK: - Keepalive

    /// Start sending periodic pings to keep the connection alive.
    private func startKeepalive() {
        stopKeepalive()

        let interval = keepaliveInterval
        let maxAge = maxConnectionAge
        keepaliveTask = Task { [weak self] in
            var consecutiveFailures = 0
            var isFirstPing = true
            while !Task.isCancelled {
                // Send the first ping after 2s so the connection stays
                // warm immediately after a session ends. Subsequent
                // pings use the full interval.
                let delay: TimeInterval = isFirstPing ? 2.0 : interval
                isFirstPing = false
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                // Only send keepalive when not in an active session.
                let (active, age): (Bool, TimeInterval?) = self.lock.withLock {
                    let a = self.sessionActive
                    let t = self.connectionEstablishedAt.map {
                        Date().timeIntervalSince($0)
                    }
                    return (a, t)
                }
                if active { continue }

                // Proactively recycle if the connection has aged out
                // during an idle period. The next startStreaming() call
                // will create a fresh connection via ensureConnected().
                if let age, age > maxAge {
                    Log.debug(
                        "[StreamingProvider] Keepalive: connection aged out "
                            + "(\(Int(age))s > \(Int(maxAge))s), tearing down"
                    )
                    await self.tearDownConnection()
                    break
                }

                do {
                    try await self.send(json: ["type": "ping"])
                    consecutiveFailures = 0
                    Log.debug("[StreamingProvider] Keepalive ping OK")
                } catch {
                    consecutiveFailures += 1
                    Log.debug(
                        "[StreamingProvider] Keepalive ping failed "
                            + "(attempt \(consecutiveFailures)): \(error)"
                    )
                    // Tear down after 2 consecutive failures rather than
                    // 1, to tolerate transient hiccups.
                    if consecutiveFailures >= 2 {
                        Log.debug(
                            "[StreamingProvider] Keepalive: \(consecutiveFailures) "
                                + "consecutive failures, tearing down"
                        )
                        await self.tearDownConnection()
                        break
                    }
                }
            }
        }
    }

    /// Stop the keepalive task.
    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Message Helpers

    private func buildStartMessage(context: AppContext, language: String?) -> [String: Any] {
        var contextDict: [String: Any] = [
            "bundle_id": context.bundleID,
            "app_name": context.appName,
            "window_title": context.windowTitle,
        ]
        if let url = context.browserURL {
            contextDict["browser_url"] = url
        }
        if let content = context.focusedFieldContent {
            contextDict["focused_field_content"] = content
        }
        if let selected = context.selectedText {
            contextDict["selected_text"] = selected
        }
        if let cursor = context.cursorPosition {
            contextDict["cursor_position"] = cursor
        }

        var message: [String: Any] = [
            "type": "start",
            "context": contextDict,
        ]
        if let language {
            message["language"] = language
        }
        return message
    }

    /// Serialize a dictionary to JSON and send it over the WebSocket.
    private func send(json dict: [String: Any]) async throws {
        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw DictationError.networkError("No active streaming session")
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            throw DictationError.networkError("Failed to encode message")
        }

        try await task.send(.string(text))
    }

    // MARK: - Receiving

    // MARK: - Timeout

    /// Run an async throwing operation with a timeout. On timeout, cancel
    /// the WebSocket task to force `receive()` to throw, then tear down.
    ///
    /// `URLSessionWebSocketTask.receive()` does not respond to structured
    /// concurrency cancellation. The only way to unblock it is to cancel
    /// the underlying task via `task.cancel()`.
    private func withTranscriptTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutOccurred = NSLock()
        var didTimeout = false

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

                timeoutOccurred.withLock { didTimeout = true }

                // Force-cancel the WebSocket task so receive() throws.
                if let self {
                    let ws: URLSessionWebSocketTask? = self.lock.withLock {
                        self.webSocketTask
                    }
                    ws?.cancel(with: .abnormalClosure, reason: nil)
                    Log.debug(
                        "[StreamingProvider] Timeout after \(Int(seconds))s, "
                            + "cancelled WebSocket to unblock receive()")
                }

                throw DictationError.networkError(
                    "Timed out waiting for server response after \(Int(seconds))s")
            }

            // The first task to finish wins. Cancel the other.
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Read WebSocket messages until `transcript_done` arrives.
    ///
    /// Return the polished text from the server. Throw on errors
    /// or if the connection closes before a result arrives.
    private func waitForResult() async throws -> String {
        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw DictationError.networkError("No active streaming session")
        }

        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw DictationError.networkError(
                    "WebSocket closed before transcript received: \(error.localizedDescription)")
            }

            switch message {
            case .string(let text):
                guard let data = text.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let type = json["type"] as? String
                else {
                    continue
                }

                switch type {
                case "transcript_done":
                    let result = json["text"] as? String ?? ""
                    return result

                case "error":
                    let errorMsg = json["error"] as? String ?? "Unknown server error"
                    throw DictationError.requestFailed(statusCode: 0, message: errorMsg)

                case "transcript_delta":
                    // Incremental transcript; could be surfaced to UI
                    // in the future. For now, ignore.
                    continue

                case "pong":
                    // Keepalive response; ignore during active session.
                    continue

                default:
                    continue
                }

            case .data:
                // Binary messages are not expected.
                continue

            @unknown default:
                continue
            }
        }
    }
}
