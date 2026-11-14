import XCTest
@testable import AgentDeckCore

final class ConnectionTests: SocketTestCase {
    private let wait1 = "GET /v1/wait/X HTTP/1.1\r\n\r\n"

    func testStartStreamBytesHeartbeatAndFinish() throws {
        try startServer { _, conn in
            conn.startStream(contentType: "application/json")
            XCTAssertTrue(conn.write(Data("    ".utf8)))
            self.queue.asyncAfter(deadline: .now() + 0.2) { _ = conn.write(Data(#"{"a":1}"#.utf8)); conn.close() }
        }
        let c = RawClient(path: path); c.send(wait1)
        let r = c.read(timeout: 2)
        XCTAssertEqual(r.text, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n    {\"a\":1}")
        XCTAssertTrue(r.eof)
    }
    func testOwnCloseDoesNotFireOnClose() throws {
        let fired = expectation(description: "onClose"); fired.isInverted = true
        try startServer { _, conn in conn.startStream(contentType: "application/json"); conn.onClose = { fired.fulfill() }; conn.close() }
        let c = RawClient(path: path); c.send(wait1); _ = c.read(timeout: 0.5)
        wait(for: [fired], timeout: 0.4)
    }
    func testPeerCloseFiresOnCloseAndWriteReturnsFalseAndServerSurvives() throws {   // Review Focus #2
        let closed = expectation(description: "onClose"); let ready = expectation(description: "handler"); var held: Connection?
        try startServer { req, conn in
            if req.path == "/ping" { conn.respond(status: 204, body: Data(), contentType: nil); return }
            held = conn; conn.startStream(contentType: "application/json"); conn.onClose = { closed.fulfill() }; ready.fulfill()
        }
        var c: RawClient? = RawClient(path: path); c!.send(wait1)
        wait(for: [ready], timeout: 1)
        c = nil   // the client closes its fd
        wait(for: [closed], timeout: 2)
        XCTAssertFalse(queue.sync { held!.write(Data("    ".utf8)) })
        let again = RawClient(path: path); again.send("GET /ping HTTP/1.1\r\n\r\n")
        XCTAssertTrue(again.read(timeout: 1).text.hasPrefix("HTTP/1.1 204"))   // the process was not killed by SIGPIPE
    }
    func testWritesRacingAPeerResetFailCleanlyAndFireOnCloseOnce() throws {   // Review Focus #2
        let ready = expectation(description: "handler"); var held: Connection?; var closes = 0
        try startServer { _, conn in held = conn; conn.startStream(contentType: "application/json"); conn.onClose = { closes += 1 }; ready.fulfill() }
        var c: RawClient? = RawClient(path: path); c!.send(wait1)
        wait(for: [ready], timeout: 1)
        c = nil
        var sawFalse = false
        queue.sync {   // blocks the read source, so only the write path can notice the dead peer (EPIPE)
            for _ in 0..<500 { if !held!.write(Data("    ".utf8)) { sawFalse = true; break }; usleep(2000) }
        }
        XCTAssertTrue(sawFalse)
        queue.sync {}; XCTAssertEqual(closes, 1)
        XCTAssertFalse(queue.sync { held!.write(Data("x".utf8)) })
    }
    func testStopUnlinksTheSocketAndClosesOpenClients() throws {
        try startServer { _, conn in conn.startStream(contentType: "application/json") }
        let c = RawClient(path: path); c.send(wait1); _ = c.read(timeout: 0.3, until: "\r\n\r\n")
        server!.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(c.read(timeout: 1).eof)
    }
}
