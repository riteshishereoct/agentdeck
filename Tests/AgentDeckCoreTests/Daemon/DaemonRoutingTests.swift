import XCTest
@testable import AgentDeckCore

final class DaemonRoutingTests: XCTestCase {
    var h: DaemonHarness!
    override func tearDown() { h?.stop() }

    func testRoutes() throws {
        h = try DaemonHarness()                                  // no capabilities file → every category .notify
        XCTAssertEqual(h.code(["--data-binary", "{}", "http://adeck/v1/event/Stop"]), "204")       // undecodable: still 204
        XCTAssertEqual(h.code(["--data-binary", "x", "http://adeck/v1/event/Nope"]), "204")
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", bashBody), "PASS")
        XCTAssertEqual(h.curl(["--data-binary", "not json", "http://adeck/v1/gate/PreToolUse"]), "PASS")
        XCTAssertEqual(h.curl(["--data-binary", "{}", "http://adeck/v1/decide/PermissionRequest"]), "PASS")
        XCTAssertEqual(h.code(["http://adeck/v1/wait/NOPE"]), "404")
        XCTAssertEqual(h.code(["--data-binary", "{}", "http://adeck/v1/gate/Stop"]), "404")
        XCTAssertEqual(h.code(["http://adeck/v2/anything"]), "404")
    }
    func testHoldWaitAllowDeliversThePermissionAllowEnvelope() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let verb = h.post("/v1/decide/PermissionRequest", bashBody)
        XCTAssertTrue(verb.hasPrefix("HOLD ")); let id = String(verb.dropFirst(5)); XCTAssertEqual(id.count, 36)
        let wait = h.launchCurl(["-m", "10", "http://adeck/v1/wait/\(id)"])
        XCTAssertTrue(h.waitUntil { h.resolve(id, .allow) == .applied })
        let out = DaemonHarness.output(wait)
        XCTAssertTrue(out.starts(with: Data("    ".utf8))); XCTAssertEqual(json(out), envelope("permission-allow"))
        XCTAssertEqual(h.code(["http://adeck/v1/wait/\(id)"]), "404")                               // one-shot
    }
    func testSecondWaitIs404AndKillingTheWaitMeansHandledElsewhere() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let id = String(h.post("/v1/decide/PermissionRequest", bashBody).dropFirst(5))
        let wait = h.launchCurl(["-m", "10", "http://adeck/v1/wait/\(id)"]); usleep(500_000)
        XCTAssertEqual(h.code(["http://adeck/v1/wait/\(id)"]), "404")                               // must not disturb the hold
        usleep(200_000); XCTAssertTrue(h.updates.isEmpty)
        wait.terminate()                                                                             // answered in Cursor: the hook is gone
        XCTAssertTrue(h.waitUntil { h.updates.map { $0.1 } == [.handledElsewhere] })
        XCTAssertEqual(h.resolve(id, .allow), .dropped(.unknownOrResolved))                          // late click after waiterClosed
        XCTAssertEqual(h.resolve(id, .allow), .dropped(.unknownOrResolved))
        XCTAssertEqual(h.updates.map { $0.1 }, [.handledElsewhere])
    }
    func testDoubleDecisionOnOneIdWritesExactlyOneEnvelope() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let id = String(h.post("/v1/decide/PermissionRequest", bashBody).dropFirst(5))
        let wait = h.launchCurl(["-m", "10", "http://adeck/v1/wait/\(id)"])
        XCTAssertTrue(h.waitUntil { h.resolve(id, .deny(note: "first")) == .applied })
        XCTAssertEqual(h.resolve(id, .allow), .dropped(.unknownOrResolved))
        XCTAssertEqual(h.resolve(id, .deny(note: "second")), .dropped(.unknownOrResolved))
        let dec = (json(DaemonHarness.output(wait))["hookSpecificOutput"] as! NSDictionary)["decision"] as! NSDictionary
        XCTAssertEqual(dec["behavior"] as? String, "deny"); XCTAssertEqual(dec["message"] as? String, "Denied in AgentDeck: first")
        XCTAssertEqual(h.updates.map { $0.1 }, [.denied])
    }
    func testFiftyConcurrentHeldRequestsEachResolveToTheirOwnId() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let n = 50
        let seen = PendingSeen(); h.daemon.onChange = { seen.add($0) }
        func raw(_ route: String, _ i: Int) -> String {
            var b = bashBody; b["session_id"] = "s\(i)"; b["tool_input"] = ["command": "npm install pkg\(i)"]
            let data = try! JSONSerialization.data(withJSONObject: b)
            return "POST \(route) HTTP/1.1\r\nHost: adeck\r\nX-Adeck-Host: \(cursor)\r\nContent-Length: \(data.count)\r\n\r\n" + String(decoding: data, as: UTF8.self)
        }
        // 50 hooks race to the daemon at once; each learns its own HOLD id.
        let ids = ConcurrentBox<[Int: String]>([:]); let socket = h.paths.socket.path
        DispatchQueue.concurrentPerform(iterations: n) { i in
            guard let c = try? TestUnixClient(path: socket) else { return }
            c.send(raw("/v1/decide/PermissionRequest", i))
            let body = String(decoding: c.read(for: 5).data, as: UTF8.self).components(separatedBy: "\r\n\r\n").last ?? ""
            if body.hasPrefix("HOLD ") { ids.update { $0[i] = String(body.dropFirst(5)) } }
        }
        let byIndex = ids.value
        XCTAssertEqual(byIndex.count, n); XCTAssertEqual(Set(byIndex.values).count, n, "every hold id is unique")
        // all 50 hooks now wait on their own id, concurrently
        let waits = ConcurrentBox<[Int: TestUnixClient]>([:])
        DispatchQueue.concurrentPerform(iterations: n) { i in
            guard let id = byIndex[i], let c = try? TestUnixClient(path: socket) else { return }
            c.send("GET /v1/wait/\(id) HTTP/1.1\r\nHost: adeck\r\n\r\n")
            waits.update { $0[i] = c }
        }
        XCTAssertEqual(waits.value.count, n)
        let end = Date().addingTimeInterval(5)                    // onChange is delivered on main: pump the run loop
        while seen.pending.count < n && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(seen.pending.count, n, "all 50 cards reached the store, each only after its wait attached")
        for i in 0..<n {                                           // card for id i belongs to session i and command i
            let r = seen.pending[byIndex[i]!]
            XCTAssertEqual(r?.sessionId, "s\(i)"); XCTAssertTrue(r?.preview.contains("pkg\(i)") == true, r?.preview ?? "nil")
        }
        for i in 0..<n {                                           // even → allow, odd → deny carrying its own index
            let d: Decision = i % 2 == 0 ? .allow : .deny(note: "n\(i)")
            XCTAssertEqual(h.resolve(byIndex[i]!, d), .applied, "request \(i)")
        }
        for i in 0..<n {
            let (data, eof) = waits.value[i]!.read(for: 5); XCTAssertTrue(eof, "wait \(i) closed")
            let body = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n\r\n").last ?? ""
            let hso = json(Data(body.utf8))["hookSpecificOutput"] as! NSDictionary
            let dec = hso["decision"] as! NSDictionary
            if i % 2 == 0 { XCTAssertEqual(dec["behavior"] as? String, "allow", "wait \(i)"); XCTAssertNil(dec["message"]) }
            else { XCTAssertEqual(dec["message"] as? String, "Denied in AgentDeck: n\(i)", "wait \(i)") }
        }
        XCTAssertEqual(h.updates.count, n)
        XCTAssertEqual(Set(h.updates.map { $0.0 }), Set(byIndex.values))
    }
    func testGatePassP95() throws {
        h = try DaemonHarness()
        let data = try JSONSerialization.data(withJSONObject: bashBody)
        let raw = "POST /v1/gate/PreToolUse HTTP/1.1\r\nHost: adeck\r\nX-Adeck-Host: \(cursor)\r\nContent-Length: \(data.count)\r\n\r\n"
            + String(decoding: data, as: UTF8.self)
        var times: [TimeInterval] = []
        for _ in 0..<200 {
            let t0 = Date(), c = try TestUnixClient(path: h.paths.socket.path); c.send(raw)
            let (d, eof) = c.read(for: 1); times.append(Date().timeIntervalSince(t0))
            XCTAssertTrue(eof); XCTAssertTrue(String(decoding: d, as: UTF8.self).hasSuffix("\r\n\r\nPASS"))
        }
        XCTAssertLessThan(times.sorted()[189], 0.050)            // spec §11 target ≤ 10 ms p95 is a manual perf check
    }
    func testAppPathsAndAlreadyRunning() throws {
        let p = AppPaths.live(home: URL(fileURLWithPath: "/Users/x"))
        XCTAssertEqual(p.socket.path, "/Users/x/Library/Application Support/AgentDeck/adeck.sock")
        XCTAssertEqual(p.capabilities.path, "/Users/x/Library/Application Support/AgentDeck/capabilities.json")
        XCTAssertEqual(p.snapshot.path, "/Users/x/Library/Application Support/AgentDeck/sessions.json")
        XCTAssertEqual(p.logFile.path, "/Users/x/Library/Logs/AgentDeck/agentdeck.log")
        h = try DaemonHarness()
        XCTAssertThrowsError(try Daemon(paths: h.paths, settings: AppSettings()).start()) { XCTAssertEqual($0 as? DaemonError, .alreadyRunning) }
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", bashBody), "PASS")                             // first daemon unharmed
    }
}

final class PendingSeen: @unchecked Sendable {
    private let lock = NSLock(); private var _p: [String: Request] = [:]
    func add(_ s: [Session]) { lock.lock(); for r in s.flatMap(\.pending) { _p[r.id] = r }; lock.unlock() }
    var pending: [String: Request] { lock.lock(); defer { lock.unlock() }; return _p }
}
final class ConcurrentBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func update(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}
