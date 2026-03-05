import Foundation

/// Dictation provider backed by the VoiceService `/dictate` endpoint.
///
/// Send a WAV file and application context as a multipart form POST.
/// The server returns polished text ready for injection along with the
/// raw transcription.
public struct VoiceServiceDictationProvider: DictationProviding {

    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    /// Create a provider with explicit configuration.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the VoiceService.
    ///   - apiKey: Bearer token for authentication.
    ///   - session: URLSession to use for requests (default: shared).
    public init(
        baseURL: String? = nil,
        apiKey: String? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL ?? ServiceConfig.baseURL
        self.apiKey = apiKey ?? ServiceConfig.apiKey

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - DictationProviding

    public func dictate(audio: Data, context: AppContext) async throws -> String {
        guard !audio.isEmpty else {
            throw DictationError.emptyAudio
        }

        let request = try buildRequest(audio: audio, context: context)
        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DictationError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseResult(from: data)
        case 401:
            throw DictationError.authenticationFailed
        default:
            let message =
                parseErrorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw DictationError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }
    }

    // MARK: - Request Construction

    /// Build a multipart form POST request for the /dictate endpoint.
    func buildRequest(audio: Data, context: AppContext) throws -> URLRequest {
        let boundary = "VoiceKit-" + UUID().uuidString
        let crlf = "\r\n"

        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/dictate") else {
            throw DictationError.networkError("Invalid base URL: " + baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=" + boundary,
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")

        var body = Data()

        // Audio file field.
        body.appendString("--" + boundary + crlf)
        body.appendString(
            "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"" + crlf)
        body.appendString("Content-Type: audio/wav" + crlf + crlf)
        body.append(audio)
        body.appendString(crlf)

        // Context JSON field.
        let contextJSON = encodeContext(context)
        body.appendString("--" + boundary + crlf)
        body.appendString("Content-Disposition: form-data; name=\"context\"" + crlf + crlf)
        body.appendString(contextJSON + crlf)

        // Closing boundary.
        body.appendString("--" + boundary + "--" + crlf)

        request.httpBody = body
        return request
    }

    // MARK: - Context Encoding

    /// Encode the AppContext as a JSON string for the multipart form field.
    private func encodeContext(_ context: AppContext) -> String {
        var dict: [String: Any] = [
            "bundle_id": context.bundleID,
            "app_name": context.appName,
            "window_title": context.windowTitle,
        ]
        if let url = context.browserURL {
            dict["browser_url"] = url
        }
        if let content = context.focusedFieldContent {
            dict["focused_field_content"] = content
        }
        if let selected = context.selectedText {
            dict["selected_text"] = selected
        }
        if let cursor = context.cursorPosition {
            dict["cursor_position"] = cursor
        }

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys])
        else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Network

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DictationError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Response Parsing

    /// Extract the "text" field from the JSON response.
    private func parseResult(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw DictationError.invalidResponse
        }
        return text
    }

    /// Try to extract a "detail" error message from a JSON error response.
    private func parseErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["detail"] as? String
    }
}

// MARK: - Data String Appending

extension Data {

    /// Append a UTF-8 encoded string to this data buffer.
    fileprivate mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
