import Foundation

/// Stream audio to the VoiceService `/stream` WebSocket endpoint for
/// real-time transcription via the OpenAI Realtime API.
///
/// The provider manages a single WebSocket session at a time. Audio
/// chunks are sent as base64-encoded PCM16 16kHz mono data. The server
/// resamples to 24kHz, forwards to the Realtime API transcription
/// session, collects the transcript, runs LLM cleanup, and returns
/// the polished text.
///
/// Protocol (client -> server):
///   1. `{"type":"start","context":{...},"language":"en"}`
///   2. `{"type":"audio","audio":"<base64 PCM16 16kHz>"}`  (repeated)
///   3. `{"type":"stop"}`
///
/// Protocol (server -> client):
///   - `{"type":"transcript_delta","delta":"..."}`
///   - `{"type":"transcript_done","text":"...","raw":"..."}`
///   - `{"type":"error","error":"..."}`
public final class VoiceServiceStreamingProvider: StreamingDictationProviding, @unchecked Sendable {

    private let baseURL: String
    private let apiKey: String

    /// Protects mutable session state across concurrent callers.
    private let lock = NSLock()
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

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
        let task = try buildWebSocketTask()

        lock.withLock {
            self.webSocketTask = task
        }

        task.resume()

        // Send the start message with context and language.
        let startMessage = buildStartMessage(context: context, language: language)
        try await send(json: startMessage)

        debugPrint("[StreamingProvider] Session started")
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

        debugPrint("[StreamingProvider] Stop sent, waiting for transcript")

        // Read messages until we receive transcript_done or error.
        let result = try await waitForResult()

        // Clean up the connection.
        await closeConnection()

        return result
    }

    public func cancelStreaming() async {
        await closeConnection()
        debugPrint("[StreamingProvider] Session cancelled")
    }

    // MARK: - WebSocket Construction

    /// Build a URLSessionWebSocketTask for the /stream endpoint.
    private func buildWebSocketTask() throws -> URLSessionWebSocketTask {
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
        config.timeoutIntervalForRequest = 120
        let session = URLSession(configuration: config)

        lock.withLock {
            self.urlSession = session
        }

        return session.webSocketTask(with: url)
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

    // MARK: - Cleanup

    private func closeConnection() async {
        let (task, session): (URLSessionWebSocketTask?, URLSession?) = lock.withLock {
            let t = self.webSocketTask
            let s = self.urlSession
            self.webSocketTask = nil
            self.urlSession = nil
            return (t, s)
        }

        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }
}
