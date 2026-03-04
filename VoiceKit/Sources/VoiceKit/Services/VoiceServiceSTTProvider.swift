import Foundation

/// Transcribe audio by calling the VoiceService `/transcribe` endpoint.
///
/// Send a WAV file as a multipart form POST and parse the JSON response.
/// The VoiceService runs as an Autonomy app and delegates to the gateway
/// speech-to-text API internally.
public struct VoiceServiceSTTProvider: STTProviding {

    private let baseURL: String
    private let apiKey: String
    private let session: URLSession

    /// Create a provider with explicit configuration.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the VoiceService (e.g. `https://cluster-voice.cluster.autonomy.computer`).
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
            config.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - STTProviding

    public func transcribe(audio: Data) async throws -> String {
        guard !audio.isEmpty else {
            throw STTError.emptyAudio
        }

        let request = try buildRequest(audio: audio)
        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw STTError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseTranscription(from: data)
        case 401:
            throw STTError.authenticationFailed
        default:
            let message = parseErrorMessage(from: data)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw STTError.transcriptionFailed(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }
    }

    // MARK: - Request Construction

    /// Build a multipart form POST request for the /transcribe endpoint.
    func buildRequest(audio: Data) throws -> URLRequest {
        let boundary = "VoiceKit-" + UUID().uuidString
        let crlf = "\r\n"

        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed + "/transcribe") else {
            throw STTError.networkError("Invalid base URL: " + baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")

        var body = Data()

        // File field
        body.appendString("--" + boundary + crlf)
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"" + crlf)
        body.appendString("Content-Type: audio/wav" + crlf + crlf)
        body.append(audio)
        body.appendString(crlf)

        // Model field
        body.appendString("--" + boundary + crlf)
        body.appendString("Content-Disposition: form-data; name=\"model\"" + crlf + crlf)
        body.appendString("whisper-1" + crlf)

        // Closing boundary
        body.appendString("--" + boundary + "--" + crlf)

        request.httpBody = body
        return request
    }

    // MARK: - Network

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw STTError.networkError(error.localizedDescription)
        }
    }

    // MARK: - Response Parsing

    /// Extract the "text" field from a successful JSON response.
    private func parseTranscription(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw STTError.invalidResponse
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

private extension Data {

    /// Append a UTF-8 encoded string to this data buffer.
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
