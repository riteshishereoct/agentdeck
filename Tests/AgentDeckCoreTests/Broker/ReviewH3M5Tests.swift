import XCTest
@testable import AgentDeckCore

/// Review M5 (read-only backstop only inside the working directory) and H3 (notices expire so a stuck session goes quiet).
final class ReviewH3M5Tests: XCTestCase {
    func testReadOnlyToolsMayPromptOnlyOutsideTheWorkingDirectory() {
        func may(_ tool: String, _ input: [String: Any], mode: String = "default", cwd: String? = "/p") -> Bool {
            DecisionBroker.mayPrompt(tool: tool, mode: mode, input: jv(input), cwd: cwd)
        }
        XCTAssertFalse(may("Read", ["file_path": "/p/a.swift"])); XCTAssertFalse(may("Read", ["file_path": "src/a.swift"]))
        XCTAssertFalse(may("Grep", ["pattern": "x"])); XCTAssertFalse(may("Glob", ["pattern": "*", "path": "/p"]))
        XCTAssertTrue(may("Read", ["file_path": "/etc/hosts"])); XCTAssertTrue(may("Grep", ["pattern": "x", "path": "/Users/me"]))
        XCTAssertTrue(may("Glob", ["pattern": "*", "path": "../other"])); XCTAssertTrue(may("LS", ["path": "~/x"]))
        XCTAssertTrue(may("Read", ["file_path": "/pp/a"]), "a sibling folder sharing the prefix is outside")
        XCTAssertTrue(may("Read", ["file_path": "/etc/hosts"], mode: "acceptEdits"))
        XCTAssertFalse(may("Read", ["file_path": "/etc/hosts"], mode: "auto")); XCTAssertFalse(may("Read", ["file_path": "/etc/hosts"], mode: "bypassPermissions"))
        XCTAssertFalse(may("TodoWrite", [:]))
    }
    func testOutsideReadGetsTheBackstopNoticeInsideReadDoesNot() {
        let h = Harness()
        _ = h.broker.gate(call("Read", ["file_path": "/p/inside"], id: "in"), meta: ui)
        _ = h.broker.gate(call("Read", ["file_path": "/Users/other/secret"], id: "out"), meta: ui)
        h.tick(7)
        XCTAssertEqual(h.broker.pending.map(\.toolUseId), ["out"])
    }
    func testNotifyNoticeExpiresAfterTenMinutesButHeldRequestsDoNot() {
        let h = Harness([.Bash: .race])
        _ = h.broker.decide(call("Edit", ["file_path": "/p/a"]), meta: ui)          // Edit .notify: a notice
        h.tick(20)   // holds release at 590 s; start this hold later than the notice
        let (held, _) = h.holdAttached(bash("npm i"))
        h.tick(579); XCTAssertEqual(h.broker.pending.count, 2)
        h.tick(1.1)
        XCTAssertEqual(h.statuses, [.timedOut]); XCTAssertEqual(h.broker.pending.map(\.id), [held])
    }
    func testStuckNeedsYouWithOnlyAnExpiredNoticeGoesQuietAndWakesOnNewWork() {
        let notice = Make.request("n1", channel: .notify)
        var s = Reducer.apply(nil, Make.event(.requestHeld(notice), at: Make.t0))
        XCTAssertEqual(s.state, .needsYou)
        s = Reducer.apply(s, Make.event(.requestUpdated(id: "n1", status: .timedOut), at: Make.t(600)))
        XCTAssertEqual(s.state, .quiet); XCTAssertTrue(s.pending.isEmpty)
        s = Reducer.apply(s, Make.event(.hook(.preToolUse), tool: "Bash", at: Make.t(700)))
        XCTAssertEqual(s.state, .working)
        var both = Reducer.apply(nil, Make.event(.requestHeld(notice), at: Make.t0))
        both = Reducer.apply(both, Make.event(.requestHeld(Make.request("r1")), at: Make.t0))
        both = Reducer.apply(both, Make.event(.requestUpdated(id: "n1", status: .timedOut), at: Make.t(600)))
        XCTAssertEqual(both.state, .needsYou); XCTAssertEqual(both.pending.map(\.id), ["r1"])
    }
}
