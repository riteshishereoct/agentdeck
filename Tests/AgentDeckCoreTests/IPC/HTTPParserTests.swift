import XCTest
@testable import AgentDeckCore

final class HTTPParserTests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }
    private let post = "POST /v1/event/Stop HTTP/1.1\r\nHost: adeck\r\nX-Adeck-Pid: 12\r\nContent-Length: 2\r\n\r\n"

    func testPartialBuffersNeedMore() {
        XCTAssertEqual(HTTPParser.parse(d("")), .needMore)
        XCTAssertEqual(HTTPParser.parse(d("POST /v1/event/Stop HTT")), .needMore)
        XCTAssertEqual(HTTPParser.parse(d(post + "{")), .needMore)
    }
    func testCompleteRequestLowercasesHeadersAndReportsConsumed() {
        guard case let .complete(r, consumed) = HTTPParser.parse(d(post + "{}")) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/v1/event/Stop")
        XCTAssertEqual(r.headers["x-adeck-pid"], "12"); XCTAssertEqual(r.headers["host"], "adeck"); XCTAssertEqual(r.body, d("{}"))
        XCTAssertEqual(consumed, (post + "{}").utf8.count)
    }
    func testBodySliceIndicesDoNotMatter() {
        let big = d("xx" + post + "{}"); let slice = big[2...]   // a Data slice does not start at index 0
        guard case let .complete(r, _) = HTTPParser.parse(slice) else { return XCTFail() }
        XCTAssertEqual(r.body, d("{}"))
    }
    func testExpectContinueBeforeBodyThenCompleteOnceBodyArrives() {
        let head = "POST /v1/gate/PreToolUse HTTP/1.1\r\nContent-Length: 2097152\r\nExpect: 100-continue\r\n\r\n"
        XCTAssertEqual(HTTPParser.parse(d(head)), .expectContinue)
        XCTAssertEqual(HTTPParser.parse(d(head) + Data(count: 1000)), .expectContinue)
        guard case let .complete(r, _) = HTTPParser.parse(d(head) + Data(count: 2_097_152)) else { return XCTFail() }
        XCTAssertEqual(r.body.count, 2_097_152)
    }
    func testErrors() {
        XCTAssertEqual(HTTPParser.parse(d("POST /v1/event/Stop HTTP/1.1\r\nHost: a\r\n\r\n")), .error(status: 411))
        XCTAssertEqual(HTTPParser.parse(d("POST /x HTTP/1.1\r\nContent-Length: 8388609\r\n\r\n")), .error(status: 413))
        XCTAssertEqual(HTTPParser.parse(d("POST /x HTTP/1.1\r\nContent-Length: 8388608\r\n\r\n")), .needMore)
        XCTAssertEqual(HTTPParser.parse(d("POST /x HTTP/1.1\r\nX: " + String(repeating: "a", count: 17_000) + "\r\n\r\n")), .error(status: 431))
        XCTAssertEqual(HTTPParser.parse(d("GET /x HTTP/1.1\r\nX: " + String(repeating: "a", count: 17_000))), .error(status: 431))   // no terminator yet
        XCTAssertEqual(HTTPParser.parse(d("garbage\r\n\r\n")), .error(status: 400))
        XCTAssertEqual(HTTPParser.parse(d("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n")), .error(status: 400))
    }
    func testGetWithoutBodyIsCompleteAndZeroLengthPostIsComplete() {
        guard case let .complete(g, _) = HTTPParser.parse(d("GET /v1/wait/ABC HTTP/1.1\r\nHost: adeck\r\n\r\n")) else { return XCTFail() }
        XCTAssertEqual(g.method, "GET"); XCTAssertEqual(g.path, "/v1/wait/ABC"); XCTAssertTrue(g.body.isEmpty)
        guard case let .complete(p, _) = HTTPParser.parse(d("POST /x HTTP/1.1\r\nContent-Length: 0\r\n\r\n")) else { return XCTFail() }
        XCTAssertTrue(p.body.isEmpty)
    }
}
