import Foundation
import Network
import XCTest

@testable import VoiceKit

// MARK: - Local WebSocket Test Server

/// A minimal WebSocket server that speaks the VoiceServiceStreamingProvider
/// protocol. Runs on localhost with a random port. Each accepted connection
/// responds to `ping` with `pong`, echoes `start`/`audio` as acks, and
/// replies to `stop` with `transcript_done`.
///
/// The server can forcibly kill individual connections to simulate stale
/// primaries, which is the key scenario for backup promotion testing.
private final class LocalWebSocketServer {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test-ws-server")
    private let lock = NSLock()

    private var _connections: [NWConnection] = []
    private var _connectionCount: Int = 0
    private var _ready = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    /// The port the server is listening on (available after `start()`).
    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    /// Number of WebSocket connections accepted since the server started.
    var connectionCount: Int {
        lock.withLock { _connectionCount }
    }

    /// All currently live connections, oldest first.
    var connections: [NWConnection] {
        lock.withLock { _connections }
    }

    init() throws {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let params = NWParameters(tls: nil)
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        listener = try NWListener(using: params, on: .any)
    }

    /// Start listening and wait until the server is ready.
    func start() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.withLock { readyContinuation = cont }

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .ready = state {
                    let c: CheckedContinuation<Void, Never>? = self.lock.withLock {
                        let c = self.readyContinuation
                        self.readyContinuation = nil
                        self._ready = true
                        return c
                    }
                    c?.resume()
                }
            }

            listener.newConnectionHandler = { [weak self] conn in
                self?.handleNewConnection(conn)
            }

            listener.start(queue: queue)
        }
    }

    /// Stop the server and cancel all connections.
    func stop() {
        listener.cancel()
        let conns: [NWConnection] = lock.withLock {
            let c = _connections
            _connections.removeAll()
            return c
        }
        for conn in conns {
            conn.cancel()
        }
    }

    /// Forcibly kill the Nth connection (0-based). Simulates a stale
    /// primary WebSocket dying between dictation sessions.
    func killConnection(at index: Int) {
        let conn: NWConnection? = lock.withLock {
            guard index < _connections.count else { return nil }
            let c = _connections[index]
            _connections.remove(at: index)
            return c
        }
        conn?.forceCancel()
    }

    /// Kill the oldest connection (the primary, typically).
    func killOldestConnection() {
        killConnection(at: 0)
    }

    // MARK: - Private

    private func handleNewConnection(_ conn: NWConnection) {
        lock.withLock {
            _connections.append(conn)
            _connectionCount += 1
        }

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .cancelled, .failed:
                guard let self, let conn else { return }
                self.lock.withLock {
                    self._connections.removeAll { $0 === conn }
                }
            default:
                break
            }
        }

        conn.start(queue: queue)
        receiveMessages(on: conn)
    }

    private func receiveMessages(on conn: NWConnection) {
        conn.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self else { return }

            if error != nil {
                self.lock.withLock {
                    self._connections.removeAll { $0 === conn }
                }
                return
            }

            if let data = content,
                String(data: data, encoding: .utf8) != nil,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = json["type"] as? String
            {
                self.handleMessage(type: type, json: json, on: conn)
            }

            // Always schedule the next read unless the connection is
            // done. Without this, a nil-content delivery (e.g. after
            // sending a response) silently kills the read loop and
            // subsequent messages on this connection are never received.
            guard conn.state == .ready else {
                self.lock.withLock {
                    self._connections.removeAll { $0 === conn }
                }
                return
            }
            self.receiveMessages(on: conn)
        }
    }

    private func handleMessage(type: String, json: [String: Any], on conn: NWConnection) {
        switch type {
        case "ping":
            sendJSON(["type": "pong"], on: conn)

        case "start":
            // Acknowledge silently; session is open.
            break

        case "audio":
            // Acknowledge silently; audio received.
            break

        case "stop":
            // Reply with transcript_done.
            sendJSON(
                [
                    "type": "transcript_done",
                    "text": "Test transcript",
                    "raw": "test transcript",
                ], on: conn)

        default:
            break
        }
    }

    private func sendJSON(_ dict: [String: Any], on conn: NWConnection) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let text = String(data: data, encoding: .utf8)
        else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "ws-text",
            isFinal: false,
            metadata: [metadata]
        )

        conn.send(
            content: text.data(using: .utf8),
            contentContext: context,
            completion: .idempotent
        )
    }
}

// MARK: - Tests

/// Integration tests for the backup WebSocket connection in
/// `VoiceServiceStreamingProvider`. These tests run a local WebSocket
/// server and exercise real connection management: establishment,
/// keepalive, promotion, and teardown.
final class BackupConnectionTests: XCTestCase {

    private var server: LocalWebSocketServer!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VOICE_TEST_SLOW"] == "1",
            "Slow backup connection tests skipped (set VOICE_TEST_SLOW=1 to run)")
        try await super.setUp()
        server = try LocalWebSocketServer()
        await server.start()
        XCTAssertTrue(server.port > 0, "Server should be listening on a port")
    }

    override func tearDown() async throws {
        server?.stop()
        server = nil
        try await super.tearDown()
    }

    /// Poll a condition up to `timeout` seconds, sleeping `interval` between checks.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        interval: TimeInterval = 0.1,
        _ condition: () -> Bool
    ) async throws {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !condition() {
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func makeProvider() -> VoiceServiceStreamingProvider {
        VoiceServiceStreamingProvider(
            baseURL: "http://127.0.0.1:\(server.port)",
            apiKey: "test-key"
        )
    }

    /// Run one full dictation session: start → sendAudio → finish.
    private func runSession(on provider: VoiceServiceStreamingProvider) async throws -> String {
        try await provider.startStreaming(context: .empty, language: nil, micProximity: .nearField)
        // Send a small chunk of fake PCM audio.
        try await provider.sendAudio(Data(repeating: 0, count: 3200))
        return try await provider.finishStreaming()
    }

    // MARK: - Tests

    /// After a successful session, the provider should establish a backup
    /// connection. Verify by checking the server's connection count: one
    /// primary + one backup = 2.
    func testBackupEstablishedAfterSession() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        let result = try await runSession(on: provider)
        XCTAssertEqual(result, "Test transcript")

        // The backup is established asynchronously. Wait briefly.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            server.connectionCount, 2,
            "Server should have 2 connections: primary + backup"
        )
    }

    /// When the primary dies between sessions, the next session should
    /// succeed by promoting the backup. The promotion should be fast
    /// (under 2s) rather than hitting the 3s ping timeout + reconnect.
    func testBackupPromotedWhenPrimaryDies() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // First session: establishes primary, then backup.
        let result1 = try await runSession(on: provider)
        XCTAssertEqual(result1, "Test transcript")

        // Wait for backup to be established.
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // Kill the primary (oldest connection). This simulates a stale
        // WebSocket that would fail the liveness ping.
        server.killOldestConnection()

        // Small delay so the server-side cancel propagates.
        try await Task.sleep(nanoseconds: 100_000_000)

        // Second session: should promote backup, not build a new connection.
        let t0 = CFAbsoluteTimeGetCurrent()
        let result2 = try await runSession(on: provider)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0

        XCTAssertEqual(result2, "Test transcript")
        XCTAssertLessThan(
            elapsed, 2.0,
            "Backup promotion should be fast (< 2s), not hit the 3s ping timeout. "
                + "Actual: \(String(format: "%.2f", elapsed))s"
        )
    }

    /// After backup promotion, a new backup should be established for
    /// the next potential failure.
    func testNewBackupEstablishedAfterPromotion() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // Session 1: primary + backup.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // Kill primary.
        server.killOldestConnection()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Session 2: promotes backup, then establishes a new backup.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)

        // We should have seen 3 total connections: original primary,
        // original backup (promoted), and new backup.
        XCTAssertEqual(
            server.connectionCount, 3,
            "Should have 3 total connections: original primary, promoted backup, new backup"
        )
    }

    /// Multiple consecutive sessions without failures should not
    /// accumulate backup connections. Only one backup at a time.
    func testOnlyOneBackupAtATime() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // Run 3 sessions back-to-back.
        for _ in 0..<3 {
            _ = try await runSession(on: provider)
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        // Should have 2 connections: one primary, one backup.
        // (Not 4: primary + 3 backups.)
        let liveCount = server.connections.count
        XCTAssertEqual(
            liveCount, 2,
            "Should have exactly 2 live connections (primary + 1 backup), not \(liveCount)"
        )
    }

    /// `disconnect()` tears down both primary and backup.
    func testDisconnectTearsDownBoth() async throws {
        let provider = makeProvider()

        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        await provider.disconnect()

        // Poll until the server sees both connections close. The
        // WebSocket close handshake can take a moment to propagate
        // through Network.framework on the server side.
        try await waitUntil(timeout: 3.0) {
            server.connections.count == 0
        }

        XCTAssertEqual(
            server.connections.count, 0,
            "All connections should be torn down after disconnect()"
        )
    }

    /// `cancelStreaming()` mid-session tears down both primary and backup.
    func testCancelTearsDownBoth() async throws {
        let provider = makeProvider()

        // First session to establish backup.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // Start a new session, then cancel mid-stream.
        try await provider.startStreaming(context: .empty, language: nil, micProximity: .nearField)
        try await provider.sendAudio(Data(repeating: 0, count: 3200))
        await provider.cancelStreaming()

        // Poll until the server sees both connections close.
        try await waitUntil(timeout: 3.0) {
            server.connections.count == 0
        }

        XCTAssertEqual(
            server.connections.count, 0,
            "All connections should be torn down after cancelStreaming()"
        )
    }

    /// When both primary and backup are dead, the provider should fall
    /// back to creating a fresh connection and still succeed.
    func testFreshConnectionWhenBothDead() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // Session 1: primary + backup.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // Kill both connections.
        server.killConnection(at: 0)
        server.killConnection(at: 0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(server.connections.count, 0)

        // Session 2: both dead, should create fresh and succeed.
        let result = try await runSession(on: provider)
        XCTAssertEqual(result, "Test transcript")
        XCTAssertGreaterThanOrEqual(server.connectionCount, 3)
    }

    // MARK: - Backup Dictation

    /// `dictateViaBackup` runs a full session on the backup WebSocket
    /// and returns the transcript. Verify it works end-to-end against
    /// the local server.
    func testDictateViaBackupReturnsTranscript() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // Run a normal session to establish the backup connection.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // Call dictateViaBackup with fake PCM audio.
        let pcmAudio = Data(repeating: 0, count: 64_000)
        let result = try await provider.dictateViaBackup(
            audio: pcmAudio, context: .empty, language: nil)

        XCTAssertEqual(result, "Test transcript")
    }

    /// After `dictateViaBackup` consumes the backup, the backup slot
    /// should be empty (connection torn down). A subsequent call should
    /// throw because no backup is available.
    func testDictateViaBackupConsumesBackupConnection() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // Establish backup.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // First call succeeds and consumes the backup.
        let pcmAudio = Data(repeating: 0, count: 3200)
        _ = try await provider.dictateViaBackup(
            audio: pcmAudio, context: .empty, language: nil)

        // Second call should throw — no backup available.
        do {
            _ = try await provider.dictateViaBackup(
                audio: pcmAudio, context: .empty, language: nil)
            XCTFail("Expected error when no backup is available")
        } catch {
            // Expected: no backup connection available.
        }
    }

    /// `dictateViaBackup` should work even when the primary is dead.
    /// This is the key scenario: primary stale, backup takes over for
    /// the parallel race in the pipeline.
    func testDictateViaBackupWorksWhenPrimaryDead() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        // Run a session to establish backup.
        _ = try await runSession(on: provider)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(server.connectionCount, 2)

        // Kill the primary.
        server.killOldestConnection()
        try await Task.sleep(nanoseconds: 100_000_000)

        // dictateViaBackup should still succeed — it uses the backup
        // connection independently of the primary.
        let pcmAudio = Data(repeating: 0, count: 32_000)
        let result = try await provider.dictateViaBackup(
            audio: pcmAudio, context: .empty, language: nil)

        XCTAssertEqual(result, "Test transcript")
    }

    /// When no backup exists (fresh provider, no prior session),
    /// `dictateViaBackup` should throw immediately.
    func testDictateViaBackupThrowsWhenNoBackup() async throws {
        let provider = makeProvider()
        defer { Task { await provider.disconnect() } }

        let pcmAudio = Data(repeating: 0, count: 3200)
        do {
            _ = try await provider.dictateViaBackup(
                audio: pcmAudio, context: .empty, language: nil)
            XCTFail("Expected error when no backup exists")
        } catch {
            // Expected.
        }
    }
}
