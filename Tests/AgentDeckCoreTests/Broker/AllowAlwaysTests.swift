import XCTest
@testable import AgentDeckCore

final class AllowAlwaysTests: XCTestCase {
    let sug: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm install:*"]],
                              "behavior": "allow", "destination": "localSettings"]
    func held(_ h: Harness, _ c: String, gate: Bool = false, extra: [String: Any] = [:]) -> (String, FakeWaiter) {
        var e: [String: Any] = ["permission_suggestions": [sug]]; e.merge(extra) { $1 }
        return h.holdAttached(bash(c, extra: e), gate: gate)
    }
    func testAllowAlwaysOnlyOnRaceWithAnOfferedSuggestion() {
        let h = Harness([.Bash: .race]); let (id, w) = held(h, "npm install")
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allowAlways(suggestion: jv(["type": "addRules"])), source: .click), .dropped(.notApplicable))
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allowAlways(suggestion: jv(sug)), source: .notification), .dropped(.notAllowedFromSource))
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allowAlways(suggestion: jv(sug)), source: .click), .applied)
        let dec = (json(w.bodies[0]!)["hookSpecificOutput"] as! NSDictionary)["decision"] as! NSDictionary
        XCTAssertEqual(dec["updatedPermissions"] as? NSArray, [sug] as NSArray); XCTAssertEqual(h.statuses, [.allowed])
        let hi = held(h, "rm -rf build").0
        XCTAssertEqual(h.broker.resolve(id: hi, decision: .allowAlways(suggestion: jv(sug)), source: .click), .dropped(.needsHoldConfirm))
        let g = Harness([.Bash: .gate]); g.away(); let gid = held(g, "npm install", gate: true).0
        XCTAssertEqual(g.broker.resolve(id: gid, decision: .allowAlways(suggestion: jv(sug)), source: .click), .dropped(.notApplicable))
        let po = Harness([.Bash: .race]); let pid = held(po, "npm install", extra: ["person_only": true]).0
        XCTAssertEqual(po.broker.resolve(id: pid, decision: .allowAlways(suggestion: jv(sug)), source: .click), .dropped(.personOnly))
    }
    func testAllowAlwaysEndToEndOverTheSocket() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let fx = Fixture.data("hooks/PermissionRequest-Bash.json")
        let s = try XCTUnwrap(try HookInput.decode(fx).permissionSuggestions.first)
        let verb = h.curl(["--data-binary", String(decoding: fx, as: UTF8.self), "http://adeck/v1/decide/PermissionRequest"])
        XCTAssertTrue(verb.hasPrefix("HOLD ")); let id = String(verb.dropFirst(5))
        let wait = h.launchCurl(["-m", "10", "http://adeck/v1/wait/\(id)"])
        XCTAssertTrue(h.waitUntil { h.resolve(id, .allowAlways(suggestion: s), .holdConfirmed) == .applied })
        let expected: NSDictionary = ["hookSpecificOutput": ["hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow", "updatedPermissions": [try JSONSerialization.jsonObject(with: s.compactData())]]]]
        XCTAssertEqual(json(DaemonHarness.output(wait)), expected)
    }
}
