import XCTest
@testable import AgentDeckCore

/// Harness numbers over the REAL unix socket and the real Daemon. Not live-app acceptance (spec §11 targets).
/// Every measurement prints one line with the stable prefix "PERF:" so it can be collected with grep.
final class PerfDaemonTests: XCTestCase {
    var h: DaemonHarness!
    override func tearDown() { h?.stop() }

    // MARK: helpers
    private static func ms(_ s: TimeInterval) -> Double { (s * 10_000).rounded() / 10 }
    /// Nearest-rank percentile of a non-empty sample, in milliseconds.
    private static func pct(_ xs: [TimeInterval], _ p: Double) -> Double {
        let s = xs.sorted(); return ms(s[max(0, Int((p * Double(s.count)).rounded(.up)) - 1)])
    }
    private func report(_ name: String, _ xs: [TimeInterval], _ extra: String = "") {
        let line = "PERF: \(name) n=\(xs.count) p50=\(Self.pct(xs, 0.5))ms p95=\(Self.pct(xs, 0.95))ms max=\(Self.ms(xs.max()!))ms\(extra)"
        print(line); fflush(stdout)
    }
    private func raw(_ method: String, _ route: String, _ body: [String: Any]? = nil) -> String {
        let data = body.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data()
        return "\(method) \(route) HTTP/1.1\r\nHost: adeck\r\nX-Adeck-Host: \(cursor)\r\nContent-Length: \(data.count)\r\n\r\n" + String(decoding: data, as: UTF8.self)
    }
    private func bodyOf(_ d: Data) -> String { String(decoding: d, as: UTF8.self).components(separatedBy: "\r\n\r\n").last ?? "" }
    private func post(_ route: String, _ body: [String: Any]) throws -> (body: String, eof: Bool) {
        let c = try TestUnixClient(path: h.paths.socket.path); c.send(raw("POST", route, body))
        let (d, eof) = c.read(for: 2); return (bodyOf(d), eof)
    }
    private func pump(_ seconds: TimeInterval, until done: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
    }

    // MARK: 1. gate pass-through over the socket
    func testGatePassThroughLatency() throws {
        h = try DaemonHarness(categories: ["Other": 2])          // Read is category Other; gate channel makes the broker run its full gate path
        let body: [String: Any] = ["session_id": "perf-gate", "cwd": "/p", "tool_name": "Read", "tool_input": ["file_path": "/p/a.txt"],
                                   "permission_mode": "default", "tool_use_id": "toolu_gate"]
        let req = raw("POST", "/v1/gate/PreToolUse", body)
        func once() throws -> TimeInterval {
            let t0 = Date(), c = try TestUnixClient(path: h.paths.socket.path); c.send(req)
            let (d, eof) = c.read(for: 1); let dt = Date().timeIntervalSince(t0)
            XCTAssertTrue(eof); XCTAssertEqual(bodyOf(d), "PASS"); return dt
        }
        for _ in 0..<10 { _ = try once() }                       // warm-up, not counted
        let times = try (0..<200).map { _ in try once() }
        report("gate_pass_connect_send_read", times, " threshold_p95<=10ms")
        XCTAssertLessThanOrEqual(Self.pct(times, 0.95), 10, "spec §11: gate pass-through <= 10 ms p95")
    }

    // MARK: 2. async event -> session store
    func testEventToStoreLatency() throws {
        h = try DaemonHarness()
        let sessions = (0..<10).map { "perf-ev-\($0)" }
        var seen: [String: Date] = [:]; var hit: (String, Date, Date)?   // (session, sentAt, reflectedAt), main thread only
        var wantSession = "", wantSince = Date.distantFuture
        h.daemon.onChange = { all in
            seen = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.lastEventAt) })
            if hit == nil, let at = seen[wantSession], at >= wantSince { hit = (wantSession, wantSince, Date()) }
        }
        func send(_ kind: String, _ sid: String, _ extra: [String: Any] = [:]) throws {
            var b: [String: Any] = ["session_id": sid, "cwd": "/p", "permission_mode": "default", "hook_event_name": kind]
            b.merge(extra) { $1 }
            let r = try post("/v1/event/\(kind)", b); XCTAssertTrue(r.eof)
        }
        for s in sessions { wantSession = s; wantSince = Date(); hit = nil; try send("SessionStart", s); pump(2) { hit != nil } }
        XCTAssertEqual(seen.count, 10, "all sessions created")
        var times: [TimeInterval] = []
        for i in 0..<200 {
            let sid = sessions[i % 10]
            hit = nil; wantSession = sid; wantSince = Date()
            try send("PostToolUse", sid, ["tool_name": "Bash", "tool_input": ["command": "ls \(i)"], "tool_use_id": "toolu_\(i)"])
            pump(2) { hit != nil }
            guard let (_, sent, got) = hit else { XCTFail("event \(i) never reached the store"); continue }
            times.append(got.timeIntervalSince(sent))
        }
        XCTAssertEqual(times.count, 200)
        report("event_to_store", times, " threshold_p95<=300ms includes_50ms_coalescing")
        XCTAssertLessThanOrEqual(Self.pct(times, 0.95), 300, "event -> store/UI callback <= 300 ms p95")
    }

    // MARK: 3. 10 sessions x 5 held requests
    func testTenSessionsFiveHeldRequestsStayIsolatedAndFIFO() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let nS = 10, nR = 5
        var latest: [String: [Request]] = [:]; h.daemon.onChange = { all in latest = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.pending) }) }
        struct Slot { var id = ""; var wait: TestUnixClient!; var got = Data() }
        var slot = [[Slot]](repeating: [Slot](repeating: Slot(), count: nR), count: nS)
        // Round-robin across sessions: request j of every session is issued (decide, then its own wait) before request j+1.
        for j in 0..<nR {
            for i in 0..<nS {
                let r = try post("/v1/decide/PermissionRequest", ["session_id": "perf-h\(i)", "cwd": "/p", "tool_name": "Bash",
                    "tool_input": ["command": "echo s\(i)-r\(j)"], "permission_mode": "default"])
                XCTAssertTrue(r.body.hasPrefix("HOLD "), r.body)
                slot[i][j].id = String(r.body.dropFirst(5))
                let c = try TestUnixClient(path: h.paths.socket.path); c.send(raw("GET", "/v1/wait/\(slot[i][j].id)")); slot[i][j].wait = c
            }
        }
        XCTAssertEqual(Set(slot.flatMap { $0.map(\.id) }).count, nS * nR, "50 unique hold ids")
        pump(5) { latest.values.map(\.count).reduce(0, +) == nS * nR }
        func assertCards(_ removed: Set<String>, _ line: UInt = #line) {
            for i in 0..<nS {
                let want = (0..<nR).map { slot[i][$0] }.filter { !removed.contains($0.id) }
                let have = latest["perf-h\(i)"] ?? []
                XCTAssertEqual(have.map(\.id), want.map(\.id), "session \(i): pending ids and FIFO order", line: line)
                for (r, s) in zip(have, want) { XCTAssertEqual(r.sessionId, "perf-h\(i)", line: line); XCTAssertEqual(r.status, .pending, line: line)
                    XCTAssertTrue(r.preview.contains("echo s\(i)-r\(slot[i].firstIndex { $0.id == s.id }!)"), r.preview, line: line) }
            }
        }
        assertCards([])
        // Held waits must show no decision yet: poll every wait briefly, keep what arrives.
        func poll(_ skip: Set<String> = []) -> Set<String> {
            var closed = Set<String>()
            for i in 0..<nS { for j in 0..<nR where !skip.contains(slot[i][j].id) {
                let (d, eof) = slot[i][j].wait.read(for: 0.01); slot[i][j].got.append(d); if eof { closed.insert(slot[i][j].id) } } }
            return closed
        }
        XCTAssertTrue(poll().isEmpty, "no wait ended before any resolve")
        // Resolve one in the middle: only it may end.
        let (mi, mj) = (3, 2)
        XCTAssertEqual(h.resolve(slot[mi][mj].id, .deny(note: "only-this")), .applied)
        let (d, eof) = slot[mi][mj].wait.read(for: 2); XCTAssertTrue(eof); slot[mi][mj].got.append(d)
        var done: Set<String> = [slot[mi][mj].id]
        XCTAssertTrue(poll(done).isEmpty, "resolving one request ended no other wait")
        pump(2) { (latest["perf-h\(mi)"] ?? []).count == nR - 1 }
        assertCards(done)
        // Late/double resolve of the same id drops and changes nothing.
        XCTAssertEqual(h.resolve(slot[mi][mj].id, .allow), .dropped(.unknownOrResolved))
        XCTAssertEqual(h.resolve(slot[mi][mj].id, .deny(note: "again")), .dropped(.unknownOrResolved))
        XCTAssertTrue(poll(done).isEmpty)
        // Resolve the rest in FIFO order per session, interleaved; time resolve -> that hook's EOF.
        var lat: [TimeInterval] = []
        for j in 0..<nR { for i in 0..<nS where !done.contains(slot[i][j].id) {
            let d: Decision = (i + j) % 2 == 0 ? .allow : .deny(note: "n-s\(i)-r\(j)")
            let t0 = Date(); XCTAssertEqual(h.resolve(slot[i][j].id, d), .applied)
            let (bytes, eof) = slot[i][j].wait.read(for: 2); lat.append(Date().timeIntervalSince(t0)); XCTAssertTrue(eof)
            slot[i][j].got.append(bytes); done.insert(slot[i][j].id)
        } }
        report("held_resolve_to_hook_eof", lat, " requests=\(nS * nR) sessions=\(nS)")
        // Every wait carries exactly its own decision.
        for i in 0..<nS { for j in 0..<nR {
            let env = json(Data(bodyOf(slot[i][j].got).trimmingCharacters(in: .whitespaces).utf8))
            let dec = (env["hookSpecificOutput"] as! NSDictionary)["decision"] as! NSDictionary
            if (i, j) == (mi, mj) { XCTAssertEqual(dec["message"] as? String, "Denied in AgentDeck: only-this") }
            else if (i + j) % 2 == 0 { XCTAssertEqual(dec["behavior"] as? String, "allow", "s\(i) r\(j)"); XCTAssertNil(dec["message"]) }
            else { XCTAssertEqual(dec["message"] as? String, "Denied in AgentDeck: n-s\(i)-r\(j)", "s\(i) r\(j)") }
            XCTAssertEqual(h.resolve(slot[i][j].id, .allow), .dropped(.unknownOrResolved), "late resolve s\(i) r\(j)")
        } }
        XCTAssertEqual(h.updates.count, nS * nR); XCTAssertEqual(Set(h.updates.map { $0.0 }), Set(slot.flatMap { $0.map(\.id) }))
        print("PERF: held_isolation sessions=\(nS) requests=\(nS * nR) cross_session_resolutions=0 late_resolves_dropped=\(nS * nR)"); fflush(stdout)
    }
}
