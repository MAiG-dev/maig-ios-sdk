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
        try await generateText(messages: [.user(prompt)], options: options).content
    }

    /// Returns an AsyncStream that yields token chunks as they arrive via SSE.
    public func streamText(
        prompt: String,
        options: GenerateOptions? = nil
    ) -> AsyncStream<String> {
        streamText(messages: [.user(prompt)], options: options)
    }

    public func generateText(
        messages: [Message],
        options: GenerateOptions? = nil
    ) async throws -> ChatCompletion {
        let request = try buildRequest(messages: messages, options: options, stream: false)
        return try await withRetry { [self] in
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTPResponse(response, data: data)
            return try JSONDecoder().decode(ChatCompletion.self, from: data)
        }
    }

    public func streamText(
        messages: [Message],
        options: GenerateOptions? = nil
    ) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                do {
                    let request = try self.buildRequest(messages: messages, options: options, stream: true)
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

    private func buildRequest(messages: [Message], options: GenerateOptions?, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout

        let responseFormatBody = options?.responseFormat.map { ChatRequest.ResponseFormatBody(type: $0.rawValue) }
        let body = ChatRequest(
            model: options?.model ?? "auto",
            messages: messages,
            user: options?.userId,
            maxTokens: options?.maxTokens,
            stream: stream,
            temperature: options?.temperature,
            topP: options?.topP,
            stop: options?.stop,
            frequencyPenalty: options?.frequencyPenalty,
            presencePenalty: options?.presencePenalty,
            seed: options?.seed,
            responseFormat: responseFormatBody
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

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let user: String?
    let maxTokens: Int?
    let stream: Bool
    let temperature: Double?
    let topP: Double?
    let stop: [String]?
    let frequencyPenalty: Double?
    let presencePenalty: Double?
    let seed: Int?
    let responseFormat: ResponseFormatBody?

    struct ResponseFormatBody: Encodable {
        let type: String
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, user, stream, temperature, seed
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case stop
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case responseFormat = "response_format"
    }
}

public struct Message: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: String) -> Message { Message(role: "user", content: content) }
    public static func system(_ content: String) -> Message { Message(role: "system", content: content) }
    public static func assistant(_ content: String) -> Message { Message(role: "assistant", content: content) }
}

public struct Usage: Decodable, Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
    public let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

public struct ChatCompletion: Decodable, Sendable {
    public let id: String
    public let content: String
    public let finishReason: String?
    public let usage: Usage?

    private struct Choice: Decodable {
        struct MessageBody: Decodable { let content: String? }
        let message: MessageBody
        let finish_reason: String?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case choices
        case usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let choices = try container.decode([Choice].self, forKey: .choices)
        content = choices.first?.message.content ?? ""
        finishReason = choices.first?.finish_reason
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
    }
}
