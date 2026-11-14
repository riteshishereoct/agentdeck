import XCTest
@testable import AgentDeckCore

final class SuggestionScopeTests: XCTestCase {
    let cwd = "/Users/me/proj"
    func s(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    func testSetModeAlwaysNeedsHold() {   // live incident: one-click setMode acceptEdits
        for mode in ["acceptEdits", "bypassPermissions", "default", "plan"] {
            XCTAssertTrue(SuggestionScope.needsHold(s(["type": .string("setMode"), "mode": .string(mode), "destination": .string("session")]), cwd: cwd), mode)
        }
    }
    func testUserOrProjectSettingsNeedHoldLocalAndSessionDoNot() {
        let rule: JSONValue = .array([.object(["toolName": .string("Bash"), "ruleContent": .string("npm test:*")])])
        for d in ["userSettings", "projectSettings"] {
            XCTAssertTrue(SuggestionScope.needsHold(s(["type": .string("addRules"), "rules": rule, "destination": .string(d)]), cwd: cwd), d)
        }
        for d in ["localSettings", "session"] {
            XCTAssertFalse(SuggestionScope.needsHold(s(["type": .string("addRules"), "rules": rule, "destination": .string(d)]), cwd: cwd), d)
        }
    }
    func testAddDirectoriesOutsideCwdNeedsHold() {
        func dirs(_ d: [String]) -> JSONValue { s(["type": .string("addDirectories"), "directories": .array(d.map { .string($0) }), "destination": .string("session")]) }
        XCTAssertFalse(SuggestionScope.needsHold(dirs(["/Users/me/proj/sub", "lib"]), cwd: cwd))
        XCTAssertTrue(SuggestionScope.needsHold(dirs(["/Users/me"]), cwd: cwd))
        XCTAssertTrue(SuggestionScope.needsHold(dirs(["/Users/me/proj-other"]), cwd: cwd))     // prefix but not inside
        XCTAssertTrue(SuggestionScope.needsHold(dirs(["../secrets"]), cwd: cwd))
        XCTAssertTrue(SuggestionScope.needsHold(dirs(["~/Documents"]), cwd: cwd))
        XCTAssertTrue(SuggestionScope.needsHold(dirs(["/Users/me/proj/sub"]), cwd: nil))       // unknown cwd: fail safe
        XCTAssertTrue(SuggestionScope.needsHold(dirs([]), cwd: cwd))
    }
    func testUnknownOrMalformedNeedsHold() {
        XCTAssertTrue(SuggestionScope.needsHold(.string("x"), cwd: cwd))
        XCTAssertTrue(SuggestionScope.needsHold(s(["type": .string("somethingNew"), "destination": .string("session")]), cwd: cwd))
    }
    func testPerformRequiresHoldForBroadScopeEvenAtLowRisk() {
        let c = FakeClock(); let q = CardQueue(clock: c)
        let mode = s(["type": .string("setMode"), "mode": .string("acceptEdits"), "destination": .string("session")])
        _ = q.sync(pending: [UI.request("A", suggestions: [mode])], context: QueueContext(expanded: true, cwds: ["s1": cwd])); q.didRender(topId: "A")
        c.advance(1)
        XCTAssertEqual(q.perform(.allowAlways(mode), renderedId: "A", via: .click), .dropped(.needsHold))
        XCTAssertEqual(q.perform(.allowAlways(mode), renderedId: "A", via: .hold), .send(requestId: "A", decision: .allowAlways(suggestion: mode), source: .holdConfirmed))
    }
}
