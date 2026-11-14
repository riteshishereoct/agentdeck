import XCTest
@testable import AgentDeckCore

final class EnvelopesTests: XCTestCase {
    let note = "use the test script instead"
    let sug: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]],
                              "behavior": "allow", "destination": "localSettings"]
    func hso(_ d: Data) -> NSDictionary { json(d)["hookSpecificOutput"] as! NSDictionary }

    func testAllowAndDenyMatchFixtures() throws {
        let p = makeRequest(), g = makeRequest(hook: .preToolUse, channel: .gate)
        XCTAssertEqual(json(try Envelopes.data(for: p, decision: .allow)), envelope("permission-allow"))
        XCTAssertEqual(json(try Envelopes.data(for: p, decision: .deny(note: "  \(note) \n"))), envelope("permission-deny"))
        XCTAssertEqual(json(try Envelopes.data(for: g, decision: .allow)), envelope("pretooluse-allow"))
        XCTAssertEqual(json(try Envelopes.data(for: g, decision: .deny(note: note))), envelope("pretooluse-deny"))
    }
    func testDenyNoteTrimmedCappedAndEmptyHasNoColon() throws {
        let p = makeRequest(), g = makeRequest(hook: .preToolUse, channel: .gate)
        func msg(_ n: String?) throws -> String { (hso(try Envelopes.data(for: p, decision: .deny(note: n)))["decision"] as! NSDictionary)["message"] as! String }
        XCTAssertEqual(try msg(nil), "Denied in AgentDeck")
        XCTAssertEqual(try msg(" \n "), "Denied in AgentDeck")
        XCTAssertEqual(try msg(String(repeating: "x", count: 600)), "Denied in AgentDeck: " + String(repeating: "x", count: 500))
        XCTAssertEqual(hso(try Envelopes.data(for: g, decision: .deny(note: nil)))["permissionDecisionReason"] as? String, "Denied in AgentDeck")
    }
    func testAllowAlwaysAndInvalidCombinationsThrowNotApplicable() throws {
        let r = makeRequest(suggestions: [sug])
        XCTAssertEqual(json(try Envelopes.data(for: r, decision: .allowAlways(suggestion: jv(sug)))), envelope("permission-allow-always"))
        let bad: [(Request, Decision)] = [
            (makeRequest(), .allowAlways(suggestion: jv(sug))),                                          // no suggestions
            (r, .allowAlways(suggestion: jv(["type": "addRules", "rules": [["toolName": "Bash"]]]))),    // not one of the offered
            (makeRequest(hook: .preToolUse, suggestions: [sug], channel: .gate), .allowAlways(suggestion: jv(sug))),
            (makeRequest(), .answer(["Which database?": "Postgres"])),                                   // not a question
            (makeRequest(hook: .notification, channel: .notify), .deny(note: nil)),                      // notice source has no envelope
        ]
        for (req, d) in bad {
            XCTAssertThrowsError(try Envelopes.data(for: req, decision: d)) { XCTAssertEqual($0 as? DropReason, .notApplicable) }
        }
    }
    func testAnswerKeepsEveryInputKeyAndAddsAnswers() throws {
        let fx = envelope("question-answer")
        let input = (fx["hookSpecificOutput"] as! NSDictionary)["updatedInput"] as! NSDictionary
        let base = input.mutableCopy() as! NSMutableDictionary; base.removeObject(forKey: "answers")
        func q(_ i: Any) -> Request { makeRequest(hook: .preToolUse, kind: .question, tool: "AskUserQuestion", input: i, channel: .gate) }
        XCTAssertEqual(json(try Envelopes.data(for: q(base), decision: .answer(["Which database?": "Postgres"]))), fx)
        base["metadata"] = ["source": "x"]
        let multi = hso(try Envelopes.data(for: q(base), decision: .answer(["Which database?": "Postgres, Mongo"])))
        let upd = multi["updatedInput"] as! NSDictionary
        XCTAssertEqual(upd["metadata"] as? NSDictionary, ["source": "x"])
        XCTAssertEqual(upd["answers"] as? NSDictionary, ["Which database?": "Postgres, Mongo"])   // multi-select string passes through verbatim
        XCTAssertThrowsError(try Envelopes.data(for: q(base), decision: .answer(["Not asked?": "x"])))
        XCTAssertThrowsError(try Envelopes.data(for: q(base), decision: .answer([:])))
    }
    func testNoEnvelopeEverDefersOrAsks() throws {
        let p = makeRequest(suggestions: [sug]), g = makeRequest(hook: .preToolUse, channel: .gate)
        let all = [try Envelopes.data(for: p, decision: .allow), try Envelopes.data(for: p, decision: .deny(note: "ask")),
                   try Envelopes.data(for: p, decision: .allowAlways(suggestion: jv(sug))),
                   try Envelopes.data(for: g, decision: .allow), try Envelopes.data(for: g, decision: .deny(note: nil))]
        for d in all {
            let h = hso(d), dec = h["decision"] as? NSDictionary
            XCTAssertTrue(["allow", "deny"].contains((h["permissionDecision"] ?? dec?["behavior"]) as? String ?? ""))
            XCTAssertNil(dec?["interrupt"])
        }
    }
    func testRuleText() {
        XCTAssertEqual(Envelopes.ruleText(for: jv(sug)), "Bash(npm test:*) · in this project (your local settings)")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm test:*"], ["toolName": "Read"]]])), "Bash(npm test:*), Read")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "setMode", "mode": "acceptEdits", "destination": "session"])),
                       "switch to accept-edits mode (file edits without asking) · for this session")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "addDirectories", "directories": ["/w/a"], "destination": "session"])), "access to /w/a · for this session")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "touch x"]], "destination": "userSettings"])),
                       "Bash(touch x) · for all projects")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "replaceRules", "behavior": "allow", "rules": [["toolName": "Bash", "ruleContent": "ls"]], "destination": "session"])),
                       "replace your allow rules with Bash(ls) · for this session")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "removeRules", "behavior": "deny", "rules": [["toolName": "Read"]]])), "remove deny rule Read")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "removeDirectories", "directories": ["/w/a"], "destination": "localSettings"])),
                       "remove access to /w/a · in this project (your local settings)")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "addRules", "rules": [["ruleContent": "x"]]])), "(tool not given)(x)")
        XCTAssertEqual(Envelopes.ruleText(for: jv(["type": "addRules", "behavior": "ask", "rules": [["toolName": "Bash"]]])), "ask Bash")
        // display is masked; the suggestion itself (sent in the envelope) is untouched
        let secret = jv(["type": "addRules", "behavior": "allow", "rules": [["toolName": "Bash", "ruleContent": "curl -H 'Authorization: Bearer abcdefghijklmnop1234'"]]])
        XCTAssertEqual(Envelopes.ruleText(for: secret), "Bash(curl -H 'Authorization: Bearer abcd••••')")
        XCTAssertTrue(String(decoding: try! secret.compactData(), as: UTF8.self).contains("abcdefghijklmnop1234"))
        let other: [String: Any] = ["type": "futureThing", "x": 1]
        XCTAssertEqual(json(Data(Envelopes.ruleText(for: jv(other)).utf8)), other as NSDictionary)
    }
}
