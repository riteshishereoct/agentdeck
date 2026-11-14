import XCTest
@testable import AgentDeckCore

final class SocketServerTests: SocketTestCase {
    private let post = "POST /v1/gate/PreToolUse HTTP/1.1\r\nHost: adeck\r\nX-Adeck-Pid: 42\r\nContent-Length: 2\r\n\r\n{}"

    func testPathLongerThan103BytesThrowsBeforeTouchingTheFilesystem() {
        let long = "/tmp/" + String(repeating: "a", count: 99)   // 104 bytes
        XCTAssertEqual(long.utf8.count, 104)
        XCTAssertThrowsError(try SocketServer(path: long, queue: queue, handler: { _, _ in }).start()) {
            XCTAssertEqual($0 as? DaemonError, .socketPathTooLong(bytes: 104))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: long))
    }
    func testStartCreatesDirAs0700AndSocketAs0600() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try startServer { _, _ in }
        var st = stat(); XCTAssertEqual(stat(root, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(stat(path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600); XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK)
    }
    func testLiveSocketIsNeverStolen() throws {
        try startServer { _, conn in conn.respond(status: 204, body: Data(), contentType: nil) }
        let second = SocketServer(path: path, queue: queue, handler: { _, _ in })
        XCTAssertThrowsError(try second.start()) { XCTAssertEqual($0 as? DaemonError, .alreadyRunning) }
        let c = RawClient(path: path); c.send(post)
        XCTAssertEqual(c.read(timeout: 1).text, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")   // first server still serves
    }
    func testStaleSocketFileIsUnlinkedAndReplaced() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { p in path.withCString { _ = strncpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, p.count - 1) } }
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        Darwin.close(fd)   // file stays, nobody listens
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try startServer { _, conn in conn.respond(status: 204, body: Data(), contentType: nil) }
        let c = RawClient(path: path); c.send(post); XCTAssertTrue(c.read(timeout: 1).text.hasPrefix("HTTP/1.1 204"))
    }
    func testHandlerReceivesParsedRequestAndVerbBytesAreExact() throws {
        let got = expectation(description: "handler"); var seen: HTTPRequest?
        try startServer { req, conn in
            seen = req; conn.respond(status: 200, body: Data("PASS".utf8), contentType: "text/plain; charset=utf-8"); got.fulfill()
        }
        let c = RawClient(path: path); c.send(post)
        let r = c.read(timeout: 1); wait(for: [got], timeout: 1)
        XCTAssertEqual(r.text, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: 4\r\nConnection: close\r\n\r\nPASS")
        XCTAssertTrue(r.eof)
        XCTAssertEqual(seen?.method, "POST"); XCTAssertEqual(seen?.path, "/v1/gate/PreToolUse")
        XCTAssertEqual(seen?.headers["x-adeck-pid"], "42"); XCTAssertEqual(seen?.body, Data("{}".utf8))
    }
    func testEmptyErrorResponsesCarryContentLengthZeroAnd204HasNone() throws {
        try startServer { req, conn in
            if req.path == "/nope" { conn.respond(status: 404, body: Data(), contentType: nil) } else { conn.respond(status: 204, body: Data(), contentType: nil) }
        }
        let a = RawClient(path: path); a.send("GET /nope HTTP/1.1\r\n\r\n")
        XCTAssertEqual(a.read(timeout: 1).text, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
    func testParserErrorsAreAnsweredAndNeverReachTheHandler() throws {
        let called = expectation(description: "handler"); called.isInverted = true
        try startServer { _, _ in called.fulfill() }
        let c = RawClient(path: path); c.send("POST /v1/event/Stop HTTP/1.1\r\nHost: a\r\n\r\n")
        XCTAssertEqual(c.read(timeout: 1).text, "HTTP/1.1 411 Length Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        wait(for: [called], timeout: 0.3)
    }
    func testExpectContinueIsAnsweredImmediatelyAndOnlyOnce() throws {
        let got = expectation(description: "handler"); var body = Data()
        try startServer { req, conn in body = req.body; conn.respond(status: 204, body: Data(), contentType: nil); got.fulfill() }
        let c = RawClient(path: path)
        c.send("POST /v1/gate/PreToolUse HTTP/1.1\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n")
        XCTAssertEqual(c.read(timeout: 0.3, until: "\r\n\r\n").text, "HTTP/1.1 100 Continue\r\n\r\n")
        c.send("ab"); c.send("cd")
        wait(for: [got], timeout: 1); XCTAssertEqual(body, Data("abcd".utf8))
        XCTAssertEqual(c.read(timeout: 1).text, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")   // no second 100 Continue
    }
    func testIncompleteRequestIsClosedAfterTwoSeconds() throws {
        try startServer { _, _ in XCTFail("handler must not run") }
        let c = RawClient(path: path); let t0 = Date()
        c.send("POST /v1/event/Stop HTTP/1.1\r\nContent-Le")
        let r = c.read(timeout: 4); let dt = Date().timeIntervalSince(t0)
        XCTAssertTrue(r.eof); XCTAssertGreaterThan(dt, 1.8); XCTAssertLessThan(dt, 2.6)
    }
    func testCurlWith2MiBBodyGetsItsAnswerWithinTheStep1Budget() throws {   // Review Focus #3
        let size = 2 * 1024 * 1024; var seen = 0
        try startServer { req, conn in seen = req.body.count; conn.respond(status: 200, body: Data("PASS".utf8), contentType: "text/plain; charset=utf-8") }
        let file = root + "/body.bin"; try Data(repeating: 0x41, count: size).write(to: URL(fileURLWithPath: file))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--unix-socket", path, "-m", "0.5", "--data-binary", "@" + file, "http://adeck/v1/gate/PreToolUse"]
        let out = Pipe(); p.standardOutput = out
        let t0 = Date(); try p.run(); p.waitUntilExit(); let dt = Date().timeIntervalSince(t0)
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "PASS")
        XCTAssertEqual(p.terminationStatus, 0); XCTAssertEqual(seen, size); XCTAssertLessThan(dt, 0.5)
    }
}
