import Foundation

public final class AIGatewayClient {
    private let apiKey: String
    private let baseURL: URL
    private let session: NetworkSession

    static let timeout: TimeInterval = 30
    static let maxRetries = 2

    public convenience init(apiKey: String, baseURL: URL = URL(string: "https://api.maig.dev")!) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = AIGatewayClient.timeout
        self.init(apiKey: apiKey, baseURL: baseURL, session: URLSession(configuration: config))
    }

    init(apiKey: String, baseURL: URL, session: NetworkSession) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Public API

    /// Makes a non-streaming chat completion request with retry + exponential backoff.
    public func generateText(
        prompt: String,
        options: GenerateOptions? = nil
    ) async throws -> String {
        let request = try buildRequest(prompt: prompt, options: options, stream: false)
        return try await withRetry { [self] in
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTPResponse(response, data: data)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return decoded.choices.first?.message.content ?? ""
        }
    }

    /// Returns an AsyncStream that yields token chunks as they arrive via SSE.
    public func streamText(
        prompt: String,
        options: GenerateOptions? = nil
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(prompt: prompt, options: options, stream: true)
                    let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse) = try await self.session.bytes(for: request)
                    try self.validateHTTPResponse(response, data: nil)

                    var lineBuffer = ""
                    for try await byte in asyncBytes {
                        let char = String(bytes: [byte], encoding: .utf8) ?? ""
                        lineBuffer += char
                        if char == "\n" {
                            let tokens = SSEParser.parseText(lineBuffer)
                            for token in tokens {
                                continuation.yield(token)
                            }
                            lineBuffer = ""
                        }
                    }
                } catch {
                    // Stream ends silently on error; caller can detect via task cancellation
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Private helpers

    private func buildRequest(prompt: String, options: GenerateOptions?, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout

        let body = ChatRequest(
            model: options?.model ?? "auto",
            messages: [Message(role: "user", content: prompt)],
            user: options?.userId,
            maxTokens: options?.maxTokens,
            stream: stream
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw AIGatewayError.authFailure
        default:
            let message = data.flatMap { String(data: $0, encoding: .utf8) }
            throw AIGatewayError.serverError(statusCode: http.statusCode, message: message)
        }
    }

    /// Retries `work` up to `maxRetries` times with exponential backoff (1s, 2s).
    private func withRetry<T>(_ work: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0...Self.maxRetries {
            do {
                return try await work()
            } catch let error as AIGatewayError {
                // Don't retry auth failures
                if case .authFailure = error { throw error }
                lastError = error
            } catch {
                lastError = AIGatewayError.networkError(error)
            }
            if attempt < Self.maxRetries {
                let delay = pow(2.0, Double(attempt)) // 1s, 2s
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError!
    }
}

// MARK: - Codable models

struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let user: String?
    let maxTokens: Int?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, user, stream
        case maxTokens = "max_tokens"
    }
}

struct Message: Codable {
    let role: String
    let content: String
}

struct ChatResponse: Decodable {
    let choices: [Choice]
}

struct Choice: Decodable {
    let message: Message
}
