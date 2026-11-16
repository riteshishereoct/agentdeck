import XCTest
@testable import AgentDeckCore

/// `POST /v1/external/claim` + `resolve`: another channel answers one exact held request.
final class ExternalResolveTests: XCTestCase {
    private func hold(_ h: DaemonHarness, _ input: [String: Any], session: String = "s1") -> (id: String, wait: Process) {
        var b = bashBody; b["session_id"] = session; b["tool_input"] = input
        let id = String(h.post("/v1/decide/PermissionRequest", b).dropFirst(5))
        let wait = h.launchCurl(["-m", "10", "http://adeck/v1/wait/\(id)"]); usleep(300_000)
        return (id, wait)
    }
    private func claim(_ h: DaemonHarness, _ input: [String: Any], session: String = "s1") -> (code: String, id: String?) {
        let b: [String: Any] = ["session_id": session, "tool_name": "Bash", "tool_input": input]
        let out = h.curl(["-w", "\n%{http_code}", "--data-binary", String(decoding: try! JSONSerialization.data(withJSONObject: b), as: UTF8.self),
                          "http://adeck/v1/external/claim"])
        let p = out.components(separatedBy: "\n"), data = Data(p.dropLast().joined(separator: "\n").utf8)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (p.last ?? "", body?["request_id"] as? String)
    }
    private func ext(_ h: DaemonHarness, requestId: String, verdict: String = "allow", message: String? = nil,
                     extra: [String: Any] = [:]) -> (code: String, body: String) {
        var b: [String: Any] = ["request_id": requestId, "verdict": verdict, "source": "slack"]
        if let message { b["message"] = message }
        b.merge(extra) { $1 }
        let out = h.curl(["-w", "\n%{http_code}", "--data-binary", String(decoding: try! JSONSerialization.data(withJSONObject: b), as: UTF8.self),
                          "http://adeck/v1/external/resolve"])
        let p = out.components(separatedBy: "\n"); return (p.last ?? "", p.dropLast().joined(separator: "\n"))
    }
    private func decision(_ wait: Process) -> String { String(decoding: DaemonHarness.output(wait), as: UTF8.self) }

    func testMatchResolvesAllowOnceAndShowsDecision() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let held = hold(h, ["command": "npm install"]), wait = held.wait
        let claimed = claim(h, ["command": "npm install"]); let r = ext(h, requestId: try XCTUnwrap(claimed.id))
        XCTAssertEqual(claimed.code, "200")
        XCTAssertEqual(r.code, "200"); XCTAssertEqual(r.body, #"{"resolved":true}"#)
        XCTAssertTrue(decision(wait).contains(#""behavior":"allow""#))
        XCTAssertTrue(h.waitUntil { h.updates.map { $0.1 } == [.allowed] })        // card leaves the panel
    }
    func testNoMatch404() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let held = hold(h, ["command": "npm install"]), wait = held.wait
        XCTAssertEqual(claim(h, ["command": "other"]).code, "404")
        XCTAssertEqual(claim(h, ["command": "npm install"], session: "other").code, "404")
        wait.terminate()
    }
    func testAmbiguous409() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let a = hold(h, ["command": "npm install"]), b = hold(h, ["command": "npm install"])
        XCTAssertEqual(claim(h, ["command": "npm install"]).code, "409")
        a.wait.terminate(); b.wait.terminate()
    }
    func testAlreadyResolved409() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let held = hold(h, ["command": "npm install"])
        let requestId = try XCTUnwrap(claim(h, ["command": "npm install"]).id)
        XCTAssertEqual(h.resolve(held.id, .allow), .applied)                       // answered in the panel first
        _ = decision(held.wait)
        XCTAssertEqual(ext(h, requestId: requestId).code, "409")
    }
    func testDenyPassesMessageThrough() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let held = hold(h, ["command": "npm install"]), wait = held.wait
        let requestId = try XCTUnwrap(claim(h, ["command": "npm install"]).id)
        XCTAssertEqual(ext(h, requestId: requestId, verdict: "deny", message: "no thanks").code, "200")
        let d = decision(wait)
        XCTAssertTrue(d.contains(#""behavior":"deny""#)); XCTAssertTrue(d.contains("no thanks"))
    }
    func testGuardRulesRejectBadVerdictAndExtraPermissions() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let held = hold(h, ["command": "npm install"]), wait = held.wait
        let requestId = try XCTUnwrap(claim(h, ["command": "npm install"]).id)
        XCTAssertEqual(ext(h, requestId: requestId, verdict: "allow_always").code, "400")
        XCTAssertEqual(ext(h, requestId: requestId, verdict: "ask").code, "400")
        // Extra fields are ignored: an allow can never carry updatedPermissions / updatedInput.
        XCTAssertEqual(ext(h, requestId: requestId, extra: ["updatedPermissions": [["x": 1]], "updatedInput": ["command": "evil"]]).code, "200")
        let d = decision(wait)
        XCTAssertFalse(d.contains("updatedPermissions")); XCTAssertFalse(d.contains("updatedInput")); XCTAssertFalse(d.contains("evil"))
    }
    func testLateAnswerCannotResolveNextIdenticalRequest() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let first = hold(h, ["command": "npm install"])
        let firstClaim = try XCTUnwrap(claim(h, ["command": "npm install"]).id)
        XCTAssertEqual(h.resolve(first.id, .allow), .applied); _ = decision(first.wait)
        let second = hold(h, ["command": "npm install"])
        XCTAssertEqual(ext(h, requestId: firstClaim).code, "409")
        let secondClaim = try XCTUnwrap(claim(h, ["command": "npm install"]).id)
        XCTAssertEqual(ext(h, requestId: secondClaim).code, "200")
        XCTAssertTrue(decision(second.wait).contains(#""behavior":"allow""#))
    }
}
