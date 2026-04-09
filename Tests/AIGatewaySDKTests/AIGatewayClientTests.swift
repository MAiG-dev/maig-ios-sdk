import XCTest
@testable import AIGatewaySDK

final class AIGatewayClientTests: XCTestCase {

    private let baseURL = URL(string: "https://api.test.com")!

    // MARK: - generateText success

    func testGenerateTextReturnsContent() async throws {
        let mock = MockNetworkSession()
        mock.dataResponses = [(
            try makeChatResponseData(content: "Hello there!"),
            makeHTTPResponse(statusCode: 200)
        )]

        let client = AIGatewayClient(apiKey: "maig_test", baseURL: baseURL, session: mock)
        let result = try await client.generateText(prompt: "Hello")

        XCTAssertEqual(result, "Hello there!")
    }

    // MARK: - Auth failure (no retry)

    func testGenerateTextThrowsAuthFailureOn401() async throws {
        let mock = MockNetworkSession()
        mock.dataResponses = [(
            Data(),
            makeHTTPResponse(statusCode: 401)
        )]

        let client = AIGatewayClient(apiKey: "maig_bad", baseURL: baseURL, session: mock)

        do {
            _ = try await client.generateText(prompt: "Hello")
            XCTFail("Expected authFailure")
        } catch AIGatewayError.authFailure {
            // expected
        }
    }

    // MARK: - Server error

    func testGenerateTextThrowsServerErrorOn500() async throws {
        let mock = MockNetworkSession()
        // Provide enough responses to cover all retries (3 total: 1 attempt + 2 retries)
        let errorResponse = (Data("Internal Server Error".utf8), makeHTTPResponse(statusCode: 500))
        mock.dataResponses = [errorResponse, errorResponse, errorResponse]

        let client = AIGatewayClient(apiKey: "maig_test", baseURL: baseURL, session: mock)

        do {
            _ = try await client.generateText(prompt: "Hello")
            XCTFail("Expected serverError")
        } catch AIGatewayError.serverError(let code, _) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Retry behavior

    func testGenerateTextRetriesOnNetworkError() async throws {
        let mock = MockNetworkSession()
        // First two calls fail with network error, third succeeds
        let networkErr = URLError(.notConnectedToInternet)
        mock.dataError = networkErr
        // We'll swap the error out by using a custom session that counts calls
        let retryMock = RetryMockNetworkSession(
            failTimes: 2,
            successData: try makeChatResponseData(content: "Retried!"),
            successResponse: makeHTTPResponse(statusCode: 200)
        )

        let client = AIGatewayClient(apiKey: "maig_test", baseURL: baseURL, session: retryMock)
        let result = try await client.generateText(prompt: "Hello")

        XCTAssertEqual(result, "Retried!")
        XCTAssertEqual(retryMock.callCount, 3) // 1 initial + 2 retries
    }

    func testGenerateTextDoesNotRetryAuthFailure() async throws {
        let mock = CountingMockSession(responses: [
            (.init(), makeHTTPResponse(statusCode: 401))
        ])

        let client = AIGatewayClient(apiKey: "maig_bad", baseURL: baseURL, session: mock)

        do {
            _ = try await client.generateText(prompt: "Hello")
            XCTFail("Expected authFailure")
        } catch AIGatewayError.authFailure {
            XCTAssertEqual(mock.callCount, 1, "Should not retry on auth failure")
        }
    }
}

// MARK: - Helper mock sessions

/// Fails the first `failTimes` calls with a URLError, then returns success.
final class RetryMockNetworkSession: NetworkSession {
    private let failTimes: Int
    private let successData: Data
    private let successResponse: URLResponse
    private(set) var callCount = 0

    init(failTimes: Int, successData: Data, successResponse: URLResponse) {
        self.failTimes = failTimes
        self.successData = successData
        self.successResponse = successResponse
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        if callCount <= failTimes {
            throw URLError(.notConnectedToInternet)
        }
        return (successData, successResponse)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("Not used in these tests")
    }
}

/// Returns responses in order, counting calls.
final class CountingMockSession: NetworkSession {
    private let responses: [(Data, URLResponse)]
    private(set) var callCount = 0

    init(responses: [(Data, URLResponse)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let idx = min(callCount, responses.count - 1)
        callCount += 1
        return responses[idx]
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        fatalError("Not used in these tests")
    }
}
