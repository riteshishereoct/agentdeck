import XCTest
@testable import AgentDeckCore

final class QuestionTests: XCTestCase {
    let input: [String: Any] = ["questions": [["question": "Which database?", "header": "DB", "multiSelect": false,
        "options": [["label": "Postgres", "description": "relational"], ["label": "Mongo", "description": "document"]]]]]
    func ask(_ id: String = "q1", mode: String = "default") -> HookInput { call("AskUserQuestion", input, id: id, mode: mode) }

    func testAwayQuestionOnGateChannelIsHeldAndAnswered() {
        let h = Harness([.Question: .gate]); h.away()
        let (id, w) = h.holdAttached(ask(), gate: true)
        XCTAssertEqual(h.held[0].kind, .question); XCTAssertEqual(h.held[0].channel, .gate)
        XCTAssertEqual(h.broker.resolve(id: id, decision: .answer(["Which database?": "Postgres"]), source: .click), .applied)
        XCTAssertEqual(w.bodies.compactMap { $0 }.map(json), [envelope("question-answer")]); XCTAssertEqual(h.statuses, [.answered])
        let b = Harness([.Question: .gate]); b.away()           // permission modes never bypass a question
        _ = b.hold(b.broker.gate(ask("q2", mode: "bypassPermissions"), meta: ui))
    }
    func testPresentPassesAndChannel3IsAReadOnlyNotice() {
        let p = Harness([.Question: .gate]); p.present()
        XCTAssertEqual(p.broker.gate(ask(), meta: ui), .pass); XCTAssertTrue(p.broker.pending.isEmpty)
        let n = Harness(); n.away()                              // Question .notify
        XCTAssertEqual(n.broker.gate(ask(), meta: ui), .pass)
        XCTAssertEqual(n.broker.pending.map(\.kind), [.question]); XCTAssertEqual(n.broker.pending[0].channel, .notify)
        XCTAssertEqual(n.broker.resolve(id: n.broker.pending[0].id, decision: .answer(["Which database?": "Mongo"]), source: .click), .dropped(.notApplicable))
        n.tick(7); XCTAssertEqual(n.broker.pending.count, 1)     // the backstop does not duplicate it
    }
    func testPassReasonExplainsWhyAQuestionWasNotHeld() {   // live L4 diagnosis on ext 2.1.325
        let p = Harness([.Question: .gate]); p.present()
        _ = p.broker.gate(ask(), meta: ui); XCTAssertEqual(p.broker.lastPassReason, "present")
        let m = Harness([.Question: .gate]); m.away()
        _ = m.broker.gate(ask(mode: "manual"), meta: ui); XCTAssertEqual(m.broker.lastPassReason, "unverifiedMode(manual)")
        let c = Harness(); c.away()
        _ = c.broker.gate(ask(), meta: ui); XCTAssertEqual(c.broker.lastPassReason, "channel")
        let h = Harness([.Question: .gate]); h.away()
        _ = h.broker.gate(ask(), meta: ui); XCTAssertNil(h.broker.lastPassReason)   // held: no pass reason
    }
    func testExitPlanModeIsNeverDecidable() {
        let h = Harness(); h.away()
        XCTAssertEqual(h.broker.gate(call("ExitPlanMode", ["plan": "1. do x"], id: "p1"), meta: ui), .pass)
        XCTAssertEqual(h.broker.decide(call("ExitPlanMode", ["plan": "1. do x"]), meta: ui), .pass)
        XCTAssertEqual(h.broker.pending.map(\.kind), [.planReview])                       // decide correlates to p1: no duplicate
        for s in [DecisionSource.click, .holdConfirmed] {
            XCTAssertEqual(h.broker.resolve(id: h.broker.pending[0].id, decision: .allow, source: s), .dropped(.notApplicable))
        }
        let forced = Harness([.ExitPlanMode: .race, .Question: .race])
        XCTAssertEqual(forced.broker.decide(call("ExitPlanMode", [:]), meta: ui), .pass)  // even a hand-built matrix cannot make it decidable
    }
    func testCapturedFixtureKeepsEveryInputKey() throws {
        let h = Harness([.Question: .gate]); h.away()
        let fx = Fixture.hookInput("PreToolUse-AskUserQuestion")
        let (id, w) = h.holdAttached(fx, gate: true)
        guard case .object(let obj)? = fx.toolInput, case .array(let qs)? = obj["questions"],
              let q = qs.first?["question"]?.stringValue else { return XCTFail("fixture shape changed") }
        XCTAssertEqual(h.broker.resolve(id: id, decision: .answer([q: "x"]), source: .click), .applied)
        let upd = (json(try XCTUnwrap(w.bodies.first ?? nil))["hookSpecificOutput"] as! NSDictionary)["updatedInput"] as! NSDictionary
        XCTAssertEqual(Set(upd.allKeys as! [String]), Set(obj.keys).union(["answers"]))
    }
    // plan-validation S3 / amendment A4: a question that does not parse, or an unverified mode, is a read-only notice, never a hold.
    func testMalformedQuestionOrUnknownModeIsANoticeNotAHold() {
        for (i, bad) in [["questions": "x"], ["questions": []], ["questions": [["header": "no question"]]], [:]].enumerated() {
            let h = Harness([.Question: .gate]); h.away()
            XCTAssertEqual(h.broker.gate(call("AskUserQuestion", bad, id: "m\(i)"), meta: ui), .pass, "\(bad)")
            XCTAssertEqual(h.broker.pending.map(\.channel), [.notify], "\(bad)")
        }
        let u = Harness([.Question: .gate]); u.away()
        XCTAssertEqual(u.broker.gate(ask(mode: "weird"), meta: ui), .pass)
        XCTAssertEqual(u.broker.pending.map(\.channel), [.notify])
    }
    func testDecideNeverHoldsAQuestionAndAQuestionIsNeverPlainAllowed() {
        let r = Harness([.Question: .race])
        XCTAssertEqual(r.broker.decide(ask(), meta: ui), .pass)
        XCTAssertEqual(r.broker.pending.map(\.channel), [.notify])
        let h = Harness([.Question: .gate]); h.away()
        let (id, w) = h.holdAttached(ask(), gate: true)
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .dropped(.notApplicable))  // allow without answers
        XCTAssertTrue(w.bodies.isEmpty)
        XCTAssertEqual(h.broker.resolve(id: id, decision: .deny(note: nil), source: .click), .applied)
    }
    func testUnrenderableQuestionShapesNeverHold() {
        let bad: [[String: Any]] = [
            ["questions": [["question": " " ]]],
            ["questions": [["question": "DB?"], ["question": "DB?"]]],
            ["questions": [["question": "DB?", "options": "bad"]]],
            ["questions": [["question": "DB?", "options": [["description": "missing label"]]]]],
            ["questions": [["question": "DB?", "multiSelect": "yes"]]]
        ]
        for input in bad {
            let h = Harness([.Question: .gate]); h.away()
            XCTAssertEqual(h.broker.gate(call("AskUserQuestion", input, id: "q"), meta: ui), .pass)
            XCTAssertEqual(h.broker.pending.map(\.channel), [.notify])
        }
    }

}
