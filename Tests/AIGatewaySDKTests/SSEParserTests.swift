import XCTest
@testable import AIGatewaySDK

final class SSEParserTests: XCTestCase {

    func testParseSingleChunk() {
        let input = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}
        """
        let result = SSEParser.parseText(input)
        XCTAssertEqual(result, ["Hel"])
    }

    func testParseMultipleChunks() {
        let input = """
        data: {"choices":[{"delta":{"content":"Hel"}}]}

        data: {"choices":[{"delta":{"content":"lo"}}]}

        data: [DONE]
        """
        let result = SSEParser.parseText(input)
        XCTAssertEqual(result, ["Hel", "lo"])
    }

    func testSkipsDoneMarker() {
        let input = "data: [DONE]"
        let result = SSEParser.parseText(input)
        XCTAssertTrue(result.isEmpty)
    }

    func testSkipsNonDataLines() {
        let input = """
        : keep-alive

        event: message
        data: {"choices":[{"delta":{"content":"Hi"}}]}
        """
        let result = SSEParser.parseText(input)
        XCTAssertEqual(result, ["Hi"])
    }

    func testSkipsChunksWithEmptyContent() {
        let input = """
        data: {"choices":[{"delta":{"content":""}}]}

        data: {"choices":[{"delta":{"content":"World"}}]}
        """
        let result = SSEParser.parseText(input)
        XCTAssertEqual(result, ["World"])
    }

    func testSkipsChunksWithNullContent() {
        let input = """
        data: {"choices":[{"delta":{}}]}

        data: {"choices":[{"delta":{"content":"OK"}}]}
        """
        let result = SSEParser.parseText(input)
        XCTAssertEqual(result, ["OK"])
    }

    func testInvalidJSONIsIgnored() {
        let input = "data: not-json"
        let result = SSEParser.parseText(input)
        XCTAssertTrue(result.isEmpty)
    }
}
