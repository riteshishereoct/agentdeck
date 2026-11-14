import XCTest
import Darwin
@testable import AgentDeckCore

final class WaitStreamTests: XCTestCase {
    let q = DispatchQueue(label: "agentdeck.core")
    var dir = "", server: SocketServer!
    var streams: [WaitStream] = [], closed = 0                 // touched only on q
    var sock: String { dir + "/w.sock" }

    override func setUpWithError() throws {
        var t = Array("/tmp/adk.XXXXXX".utf8CString)
        XCTAssertNotNil(mkdtemp(&t)); dir = String(cString: t)
        XCTAssertLessThanOrEqual(sock.utf8.count, 103)
        server = SocketServer(path: sock, queue: q) { [unowned self] _, conn in
            let s = WaitStream(connection: conn, queue: self.q, onClosed: { self.closed += 1 })
            s.start(); self.streams.append(s)
        }
        try server.start()
    }
    override func tearDown() { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    func open() throws -> TestUnixClient { let c = try TestUnixClient(path: sock); c.send("GET /v1/wait/x HTTP/1.1\r\nHost: adeck\r\n\r\n"); return c }
    func split(_ d: Data) -> (head: String, body: String) {
        let s = String(decoding: d, as: UTF8.self), r = s.range(of: "\r\n\r\n")!
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }

    func testHeaderThenFourSpacesEverySecond() throws {
        let (d, eof) = try open().read(for: 2.1)
        XCTAssertFalse(eof)
        let (head, body) = split(d)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        for h in ["Content-Type: application/json", "Cache-Control: no-store", "Connection: close"] { XCTAssertTrue(head.contains(h), h) }
        XCTAssertFalse(head.lowercased().contains("content-length"))
        XCTAssertEqual(Set(body), [" "]); XCTAssertEqual(body.count % 4, 0); XCTAssertGreaterThanOrEqual(body.count, 12)   // t = 0, 1, 2
    }
    func testFinishWithJSONWritesItAfterSpacesThenCloses() throws {
        let c = try open(); var d = c.read(for: 1.2).data
        q.sync { self.streams[0].finish(Data(#"{"ok":true}"#.utf8)) }
        let rest = c.read(for: 2); d.append(rest.data); XCTAssertTrue(rest.eof)
        let body = split(d).body
        XCTAssertTrue(body.hasPrefix("    ")); XCTAssertEqual(body.trimmingCharacters(in: .whitespaces), #"{"ok":true}"#)
    }
    func testFinishNilClosesWithSpacesOnly() throws {
        let c = try open(); _ = c.read(for: 0.3)
        q.sync { self.streams[0].finish(nil) }
        let (d, eof) = c.read(for: 2); XCTAssertTrue(eof); XCTAssertFalse(String(decoding: d, as: UTF8.self).contains("{"))
        q.sync { XCTAssertEqual(self.closed, 0) }                // our own close is not "the hook went away"
    }
    func testClientCloseFiresOnClosedOnceAndLaterWritesDoNotCrash() throws {
        let c = try open(); _ = c.read(for: 0.3); c.close()
        let end = Date().addingTimeInterval(2.5)
        while q.sync(execute: { self.closed }) == 0 && Date() < end { usleep(50_000) }
        Thread.sleep(forTimeInterval: 1.5)                       // more heartbeats would hit a dead fd
        q.sync { self.streams[0].finish(Data("{}".utf8)) }
        q.sync { XCTAssertEqual(self.closed, 1) }                // the process is alive and onClosed ran exactly once
    }
}
