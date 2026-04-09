import Foundation
@testable import AIGatewaySDK

final class MockNetworkSession: NetworkSession {
    // Configure these before each test
    var dataResponses: [(Data, URLResponse)] = []
    var dataError: Error?

    private var callCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let error = dataError { throw error }
        let index = min(callCount, dataResponses.count - 1)
        let response = dataResponses[index]
        callCount += 1
        return response
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        // URLSession.AsyncBytes cannot be constructed in tests; streaming is covered via SSEParserTests.
        fatalError("Use SSEParser tests for streaming coverage")
    }
}

// MARK: - Helpers

func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
    HTTPURLResponse(
        url: URL(string: "https://example.com")!,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
}

func makeChatResponseData(content: String) throws -> Data {
    let json = """
    {
      "choices": [
        { "message": { "role": "assistant", "content": "\(content)" } }
      ]
    }
    """
    return json.data(using: .utf8)!
}
