import Foundation

/// Stream audio to the FreeFlowService `/stream` WebSocket endpoint for
/// real-time transcription via the OpenAI Realtime API.
///
/// The provider maintains a persistent WebSocket connection across
/// dictation sessions. Each `startStreaming` / `sendAudio` /
/// `finishStreaming` cycle runs as one dictation session over the
/// same connection. A background keepalive sends "ping" messages
/// during idle periods, and the connection is automatically
/// re-established if it drops between sessions.
///
/// A warm backup WebSocket is established after each successful session.
/// When `ensureConnected()` discovers the primary is dead (failed ping),
/// it promotes the backup to primary near-instantly instead of building
/// a new connection from scratch. This avoids the 3-4s reconnect path
/// that races the 5s streaming-setup timeout and causes batch fallbacks.
/// Only one backup exists at a time; it gets its own keepalive pings
/// and is torn down if it goes stale.
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
public final class FreeFlowServiceStreamingProvider: StreamingDictationProviding,
    @unchecked Sendable
{

    /// Explicit overrides for testing. When non-nil these take
    /// priority over `ServiceConfig`.
    private let overrideBaseURL: String?
    private let overrideApiKey: String?

    private let config: ServiceConfig

    /// Resolved base URL: explicit override if provided, otherwise
    /// the current value from `ServiceConfig`.
    private var baseURL: String {
        overrideBaseURL ?? config.baseURL
    }

    /// Resolved auth token: explicit override if provided, otherwise
    /// the current value from `ServiceConfig`.
    private var apiKey: String {
        overrideApiKey ?? config.authToken
    }

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

    // MARK: - Backup Connection
    //
    // A warm standby WebSocket that is ready to be promoted to primary
    // when ensureConnected() discovers the primary is dead. This avoids
    // the ~3-4s reconnect path that races the 5s streaming-setup timeout
    // and causes batch fallbacks.

    /// The backup WebSocket task, established after each successful session.
    private var backupWebSocketTask: URLSessionWebSocketTask?

    /// The URLSession backing the backup WebSocket.
    private var backupURLSession: URLSession?

    /// When the backup connection was established.
    private var backupConnectionEstablishedAt: Date?

    /// Background keepalive task for the backup connection.
    private var backupKeepaliveTask: Task<Void, Never>?

    /// Whether a backup connection is currently being established.
    private var backupConnecting: Bool = false

    /// Create a provider with explicit configuration.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the FreeFlowService. When nil, reads from
    ///     `ServiceConfig` at each use (picks up onboarding changes).
    ///   - apiKey: Bearer token for authentication. When nil, reads from
    ///     `ServiceConfig` at each use.
    ///   - config: The `ServiceConfig` instance to read from when no
    ///     explicit overrides are provided. Defaults to `.shared`.
    public init(baseURL: String? = nil, apiKey: String? = nil, config: ServiceConfig = .shared) {
        self.overrideBaseURL = baseURL
        self.overrideApiKey = apiKey
        self.config = config
    }

    // MARK: - StreamingDictationProviding

    public func startStreaming(context: AppContext, language: String?, micProximity: MicProximity)
        async throws
    {
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

        // Send the start message with context, language, and mic proximity.
        let startMessage = buildStartMessage(
            context: context, language: language, micProximity: micProximity)
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

        // Establish a backup connection in the background so it is
        // ready if the primary goes stale before the next session.
        establishBackupIfNeeded()

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

        // On cancel, tear down both connections entirely. The server
        // expects stop→transcript_done flow; a mid-session cancel
        // leaves the server-side session in an undefined state, so
        // a fresh connection is needed next time. The backup is also
        // torn down because if the primary broke mid-session, the
        // backup may be stale too. A fresh backup will be established
        // after the next successful session.
        stopKeepalive()
        await tearDownConnection()
        await tearDownBackup()
    }

    /// Disconnect the persistent WebSocket. Call when the provider
    /// is no longer needed (e.g. app shutdown).
    public func disconnect() async {
        stopKeepalive()
        await tearDownConnection()
        await tearDownBackup()
        Log.debug("[StreamingProvider] Disconnected")
    }

    // MARK: - Connection Management

    /// Ensure there is a live WebSocket connection, creating one if needed.
    ///
    /// Proactively tears down connections that have exceeded the session
    /// limit or age limit before checking liveness, so the next session
    /// always starts on a healthy connection.
    ///
    /// When the primary connection is dead, checks for a warm backup
    /// before creating a new connection from scratch. Promoting a backup
    /// is near-instant and avoids the reconnect delay that races the 5s
    /// streaming-setup timeout.
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
                // Verify liveness with an application-level ping/pong.
                // Protocol-level sendPing is invisible to L7 load
                // balancers and K8s ingress, causing hangs or POSIX
                // error 53 on connections that appear healthy. The
                // application-level {"type":"ping"} travels as a normal
                // WebSocket text frame that the server echoes as
                // {"type":"pong"}, keeping L7 proxies happy.
                //
                // Timeout after 3s — generous enough for slow networks
                // while still catching dead connections before the 5s
                // streaming-setup deadline in performAudioSetup().
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            // Send application-level ping and wait for pong.
                            try await self.send(json: ["type": "ping"], on: task)
                            // Read messages until we get a pong. Other
                            // message types (transcript_delta, etc.) are
                            // discarded — they should not appear outside
                            // an active session but we handle them safely.
                            while true {
                                let msg = try await task.receive()
                                if case .string(let text) = msg,
                                    let data = text.data(using: .utf8),
                                    let json = try? JSONSerialization.jsonObject(with: data)
                                        as? [String: Any],
                                    json["type"] as? String == "pong"
                                {
                                    return
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

        // Try to promote the backup connection before creating a new one.
        // This is near-instant compared to building a fresh connection.
        if try await promoteBackupIfAvailable() {
            return
        }

        // Build and start a new connection.
        let (task, session) = try buildWebSocketTask()

        lock.withLock {
            self.webSocketTask = task
            self.urlSession = session
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
    ///
    /// The returned task and its backing URLSession are independent of
    /// any stored state. The caller is responsible for assigning them
    /// to the primary or backup slots.
    private func buildWebSocketTask() throws -> (URLSessionWebSocketTask, URLSession) {
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

        return (session.webSocketTask(with: url), session)
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

    // MARK: - Backup Connection

    /// Establish a backup WebSocket in the background. No-op if a backup
    /// already exists or one is currently being established.
    private func establishBackupIfNeeded() {
        let shouldCreate: Bool = lock.withLock {
            if backupWebSocketTask != nil || backupConnecting {
                return false
            }
            backupConnecting = true
            return true
        }
        guard shouldCreate else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let (task, session) = try self.buildWebSocketTask()
                task.resume()

                self.lock.withLock {
                    self.backupWebSocketTask = task
                    self.backupURLSession = session
                    self.backupConnectionEstablishedAt = Date()
                    self.backupConnecting = false
                }

                self.startBackupKeepalive()
                Log.debug("[StreamingProvider] Backup connection established")
            } catch {
                self.lock.withLock {
                    self.backupConnecting = false
                }
                Log.debug("[StreamingProvider] Failed to establish backup: \(error)")
            }
        }
    }

    /// Try to promote the backup to primary. Returns true if successful.
    ///
    /// Verifies the backup is alive with a protocol-level ping (1s timeout)
    /// before promoting. A dead backup is torn down silently.
    private func promoteBackupIfAvailable() async throws -> Bool {
        // Check cancellation before attempting promotion.
        try Task.checkCancellation()

        let backup: URLSessionWebSocketTask? = lock.withLock { self.backupWebSocketTask }
        guard let backup else { return false }

        // Verify the backup is alive with an application-level ping/pong
        // (1s timeout). Protocol-level sendPing is invisible to L7 load
        // balancers, so we use a normal WebSocket text frame instead.
        let isAlive: Bool
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.send(json: ["type": "ping"], on: backup)
                    while true {
                        let msg = try await backup.receive()
                        if case .string(let text) = msg,
                            let data = text.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any],
                            json["type"] as? String == "pong"
                        {
                            return
                        }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    throw CancellationError()
                }
                try await group.next()
                group.cancelAll()
            }
            isAlive = true
        } catch {
            isAlive = false
        }

        guard isAlive else {
            Log.debug("[StreamingProvider] Backup connection dead, discarding")
            await tearDownBackup()
            return false
        }

        // Promote: move backup state into primary slots.
        stopBackupKeepalive()
        lock.withLock {
            self.webSocketTask = self.backupWebSocketTask
            self.urlSession = self.backupURLSession
            self.connectionEstablishedAt = self.backupConnectionEstablishedAt
            self.sessionCount = 0
            self.backupWebSocketTask = nil
            self.backupURLSession = nil
            self.backupConnectionEstablishedAt = nil
        }

        // Start keepalive for the now-primary connection (will be paused
        // when the session starts in startStreaming).
        startKeepalive()

        Log.debug("[StreamingProvider] Promoted backup to primary")
        return true
    }

    /// Tear down the backup WebSocket and URLSession.
    private func tearDownBackup() async {
        stopBackupKeepalive()
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.backupWebSocketTask
            let s = self.backupURLSession
            self.backupWebSocketTask = nil
            self.backupURLSession = nil
            self.backupConnectionEstablishedAt = nil
            self.backupConnecting = false
            return (t, s)
        }

        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    /// Start keepalive pings for the backup connection.
    private func startBackupKeepalive() {
        stopBackupKeepalive()

        let interval = keepaliveInterval
        let maxAge = maxConnectionAge
        backupKeepaliveTask = Task { [weak self] in
            var consecutiveFailures = 0
            var isFirstPing = true
            while !Task.isCancelled {
                let delay: TimeInterval = isFirstPing ? 2.0 : interval
                isFirstPing = false
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard let self else { break }

                // Don't send backup keepalives during an active session —
                // only the primary connection matters then.
                let active: Bool = self.lock.withLock { self.sessionActive }
                if active { continue }

                // Reconnect aged backup connections instead of just
                // tearing down. This keeps a warm standby ready.
                let age: TimeInterval? = self.lock.withLock {
                    self.backupConnectionEstablishedAt.map {
                        Date().timeIntervalSince($0)
                    }
                }
                if let age, age > maxAge {
                    Log.debug(
                        "[StreamingProvider] Backup keepalive: connection aged out "
                            + "(\(Int(age))s > \(Int(maxAge))s), reconnecting"
                    )
                    await self.tearDownBackup()
                    await self.reconnectBackup()
                    break
                }

                // Send an application-level ping to the backup. This
                // generates real WebSocket text traffic that load
                // balancers and ingress proxies recognize as activity.
                // Protocol-level sendPing (TCP ping frame) is invisible
                // to many L7 proxies, causing them to kill "idle"
                // backup connections with POSIX error 53.
                let task: URLSessionWebSocketTask? = self.lock.withLock {
                    self.backupWebSocketTask
                }
                guard let task else { break }

                do {
                    try await self.send(json: ["type": "ping"], on: task)
                    // Wait for the pong response to confirm the server
                    // is alive. Timeout after 5s to avoid blocking.
                    let pong = try await withThrowingTaskGroup(of: Bool.self) { group in
                        group.addTask {
                            while true {
                                let msg = try await task.receive()
                                if case .string(let text) = msg,
                                    let data = text.data(using: .utf8),
                                    let json = try? JSONSerialization.jsonObject(with: data)
                                        as? [String: Any],
                                    json["type"] as? String == "pong"
                                {
                                    return true
                                }
                            }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: 5_000_000_000)
                            return false
                        }
                        let result = try await group.next() ?? false
                        group.cancelAll()
                        return result
                    }
                    guard pong else {
                        throw DictationError.networkError("Backup pong timeout")
                    }
                    consecutiveFailures = 0
                    Log.debug("[StreamingProvider] Backup keepalive ping OK")
                } catch {
                    consecutiveFailures += 1
                    Log.debug(
                        "[StreamingProvider] Backup keepalive ping failed "
                            + "(attempt \(consecutiveFailures)): \(error)"
                    )
                    if consecutiveFailures >= 2 {
                        Log.debug(
                            "[StreamingProvider] Backup keepalive: \(consecutiveFailures) "
                                + "consecutive failures, reconnecting"
                        )
                        await self.tearDownBackup()
                        await self.reconnectBackup()
                        break
                    }
                }
            }
        }
    }

    /// Attempt to re-establish the backup connection after teardown.
    ///
    /// Retries with increasing backoff (2s, 4s, 8s) up to 3 attempts.
    /// On success, starts a new backup keepalive loop.
    private func reconnectBackup() async {
        var attempt = 0
        let maxAttempts = 3
        var backoff: TimeInterval = 2.0

        while attempt < maxAttempts {
            guard !Task.isCancelled else { return }

            let active: Bool = lock.withLock { sessionActive }
            if active { return }

            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard !Task.isCancelled else { return }

            attempt += 1
            do {
                let (task, session) = try self.buildWebSocketTask()
                task.resume()

                // Verify the connection is actually live before
                // declaring success.
                try await verifyConnection(task)

                self.lock.withLock {
                    self.backupWebSocketTask = task
                    self.backupURLSession = session
                    self.backupConnectionEstablishedAt = Date()
                    self.backupConnecting = false
                }

                Log.debug(
                    "[StreamingProvider] Reconnected backup (attempt \(attempt))"
                )
                startBackupKeepalive()
                return
            } catch {
                Log.debug(
                    "[StreamingProvider] Backup reconnect failed "
                        + "(attempt \(attempt)/\(maxAttempts)): \(error)"
                )
                backoff *= 2
            }
        }

        Log.debug(
            "[StreamingProvider] Backup reconnect gave up after \(maxAttempts) attempts"
        )
    }

    /// Stop the backup keepalive task.
    private func stopBackupKeepalive() {
        backupKeepaliveTask?.cancel()
        backupKeepaliveTask = nil
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
                // during an idle period. Tear down and reconnect
                // immediately so the next dictation has a warm
                // connection ready.
                if let age, age > maxAge {
                    Log.debug(
                        "[StreamingProvider] Keepalive: connection aged out "
                            + "(\(Int(age))s > \(Int(maxAge))s), reconnecting"
                    )
                    await self.tearDownConnection()
                    await self.reconnectPrimary()
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
                                + "consecutive failures, reconnecting"
                        )
                        await self.tearDownConnection()
                        await self.reconnectPrimary()
                        break
                    }
                }
            }
        }
    }

    /// Attempt to re-establish the primary connection after teardown.
    ///
    /// Retries with increasing backoff (2s, 4s, 8s) up to 3 attempts.
    /// On success, starts a new keepalive loop. On failure, gives up
    /// and lets `ensureConnected()` handle it on the next dictation.
    private func reconnectPrimary() async {
        var attempt = 0
        let maxAttempts = 3
        var backoff: TimeInterval = 2.0

        while attempt < maxAttempts {
            guard !Task.isCancelled else { return }

            // Don't reconnect if a session became active while we
            // were waiting — the dictation path manages its own
            // connection via ensureConnected().
            let active: Bool = lock.withLock { sessionActive }
            if active { return }

            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard !Task.isCancelled else { return }

            attempt += 1
            do {
                let (task, session) = try buildWebSocketTask()
                task.resume()

                // Verify the connection is actually live with a
                // ping/pong before declaring success. Without this,
                // resume() can return immediately while the underlying
                // TCP connection is still dead.
                try await verifyConnection(task)

                lock.withLock {
                    self.webSocketTask = task
                    self.urlSession = session
                    self.sessionCount = 0
                    self.connectionEstablishedAt = Date()
                }

                Log.debug(
                    "[StreamingProvider] Reconnected primary (attempt \(attempt))"
                )
                startKeepalive()
                establishBackupIfNeeded()
                return
            } catch {
                Log.debug(
                    "[StreamingProvider] Primary reconnect failed "
                        + "(attempt \(attempt)/\(maxAttempts)): \(error)"
                )
                backoff *= 2
            }
        }

        Log.debug(
            "[StreamingProvider] Primary reconnect gave up after \(maxAttempts) attempts"
        )
    }

    /// Verify a WebSocket connection is live by sending a ping and
    /// waiting for a pong. Throws on timeout or failure.
    private func verifyConnection(_ task: URLSessionWebSocketTask) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.send(json: ["type": "ping"], on: task)
                while true {
                    let msg = try await task.receive()
                    if case .string(let text) = msg,
                        let data = text.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
                        json["type"] as? String == "pong"
                    {
                        return
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw CancellationError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Stop the keepalive task.
    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Message Helpers

    private func buildStartMessage(
        context: AppContext, language: String?, micProximity: MicProximity = .nearField
    ) -> [String: Any] {
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
            "mic_type": micProximity.rawValue,
        ]
        if let language {
            message["language"] = language
        }
        return message
    }

    /// Serialize a dictionary to JSON and send it over the primary WebSocket.
    private func send(json dict: [String: Any]) async throws {
        let task: URLSessionWebSocketTask? = lock.withLock { self.webSocketTask }
        guard let task else {
            throw DictationError.networkError("No active streaming session")
        }

        try await send(json: dict, on: task)
    }

    /// Serialize a dictionary to JSON and send it over a specific WebSocket task.
    private func send(json dict: [String: Any], on task: URLSessionWebSocketTask) async throws {
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
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

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

        return try await waitForResult(on: task)
    }

    /// Read WebSocket messages on a specific task until `transcript_done`.
    private func waitForResult(on task: URLSessionWebSocketTask) async throws -> String {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // The server closes with code 4001 when the session token
                // is invalid or expired. URLSessionWebSocketTask surfaces
                // this as an error whose description contains the close
                // code or reason string.
                let desc = error.localizedDescription
                if desc.contains("4001") || desc.contains("Unauthorized") {
                    throw DictationError.authenticationFailed
                }
                throw DictationError.networkError(
                    "WebSocket closed before transcript received: \(desc)")
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
                    // The server may send an auth_error type or include
                    // "unauthorized"/"401" in the error message when the
                    // token is rejected mid-session.
                    let lower = errorMsg.lowercased()
                    if lower.contains("unauthorized") || lower.contains("401")
                        || lower.contains("auth")
                    {
                        throw DictationError.authenticationFailed
                    }
                    throw DictationError.requestFailed(statusCode: 0, message: errorMsg)

                case "transcript_delta":
                    continue

                case "pong":
                    continue

                default:
                    continue
                }

            case .data:
                continue

            @unknown default:
                continue
            }
        }
    }

    // MARK: - Backup Dictation

    /// Run a full dictation session on the backup WebSocket.
    ///
    /// Opens a complete session (start → audio chunks → stop →
    /// transcript_done) on the standby backup connection. This is used
    /// as a parallel fallback in the pipeline race instead of the slower
    /// HTTP batch POST (~0.3–0.9s vs 1–2.5s).
    ///
    /// The backup connection is consumed by this call: on success it is
    /// torn down (its server-side session is complete), and on error it
    /// is also torn down (server state is undefined). A fresh backup is
    /// established by `finishStreaming()` after the race winner completes.
    ///
    /// Audio is sent as base64-encoded PCM chunks (~32 KB each) to match
    /// the format the primary uses during recording.
    public func dictateViaBackup(audio: Data, context: AppContext, language: String?) async throws
        -> String
    {
        // Grab the backup WebSocket task. Throw if no backup is available.
        stopBackupKeepalive()
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.backupWebSocketTask
            let s = self.backupURLSession
            // Detach from backup slots — this method owns the connection now.
            self.backupWebSocketTask = nil
            self.backupURLSession = nil
            self.backupConnectionEstablishedAt = nil
            return (t, s)
        }

        guard let task, let session else {
            throw DictationError.networkError("No backup connection available")
        }

        // Wrap the entire session in a closure so we can guarantee
        // teardown on all exit paths.
        func tearDown() {
            task.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        do {
            // 1. Send start message with context.
            let startMessage = buildStartMessage(context: context, language: language)
            try await send(json: startMessage, on: task)

            // 2. Send audio as base64 PCM chunks (~32 KB each).
            let chunkSize = 32_000
            var offset = 0
            while offset < audio.count {
                let end = min(offset + chunkSize, audio.count)
                let chunk = audio[offset..<end]
                let base64Audio = chunk.base64EncodedString()
                let message: [String: Any] = [
                    "type": "audio",
                    "audio": base64Audio,
                ]
                try await send(json: message, on: task)
                offset = end
            }

            // 3. Send stop signal.
            try await send(json: ["type": "stop"], on: task)

            Log.debug("[StreamingProvider] Backup dictation: stop sent, waiting for transcript")

            // 4. Wait for transcript_done with a 10s timeout.
            //    On timeout, cancel the WebSocket task to unblock receive().
            let result: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.waitForResult(on: task)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    task.cancel(with: .abnormalClosure, reason: nil)
                    throw DictationError.networkError(
                        "Backup dictation timed out waiting for transcript")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }

            Log.debug("[StreamingProvider] Backup dictation completed")
            tearDown()
            return result
        } catch {
            Log.debug("[StreamingProvider] Backup dictation failed: \(error)")
            tearDown()
            throw error
        }
    }
}
