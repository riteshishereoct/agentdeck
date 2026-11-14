import XCTest
@testable import AgentDeckCore

/// Exact binding: two sessions, each with a held PermissionRequest and a held question; nothing crosses over.
final class ConcurrentSessionsTests: XCTestCase {
    private let q: [String: Any] = ["questions": [["question": "Which?", "header": "Q", "multiSelect": false,
                                                   "options": [["label": "A", "description": ""], ["label": "B", "description": ""]]]]]
    private struct Pair { let perm: String, permW: FakeWaiter, question: String, questionW: FakeWaiter }

    private func setUp(_ h: Harness, _ s: String, agent: String? = nil) -> Pair {
        _ = h.broker.gate(call("Bash", ["command": "npm i"], id: "t-\(s)", agent: agent, session: s), meta: ui)   // correlation source
        let p = h.hold(h.broker.decide(call("Bash", ["command": "npm i"], agent: agent, session: s), meta: ui)), pw = FakeWaiter()
        XCTAssertTrue(h.broker.attach(id: p, waiter: pw))
        let qq = h.hold(h.broker.gate(call("AskUserQuestion", q, id: "q-\(s)", agent: agent, session: s), meta: ui)), qw = FakeWaiter()
        XCTAssertTrue(h.broker.attach(id: qq, waiter: qw))
        return Pair(perm: p, permW: pw, question: qq, questionW: qw)
    }
    private func harness() -> Harness { let h = Harness([.Bash: .race, .Question: .gate]); h.away(); return h }

    func testResolvingOneSessionNeverTouchesTheOther() {
        let h = harness(), a = setUp(h, "A"), b = setUp(h, "B")
        XCTAssertEqual(h.broker.resolve(id: a.perm, decision: .allow, source: .click), .applied)
        XCTAssertEqual(h.broker.resolve(id: a.question, decision: .answer(["Which?": "B"]), source: .click), .applied)
        XCTAssertEqual(a.permW.bodies.count, 1); XCTAssertEqual(a.questionW.bodies.count, 1)
        XCTAssertTrue(b.permW.bodies.isEmpty && b.questionW.bodies.isEmpty)
        XCTAssertEqual(h.broker.pending.map(\.id), [b.perm, b.question])
        XCTAssertEqual(h.broker.pending.map(\.sessionId), ["B", "B"])
    }

    func testStaleOrUnknownIdIsDroppedAndDoubleResolveAppliesExactlyOnce() {
        let h = harness(), a = setUp(h, "A"), b = setUp(h, "B")
        XCTAssertEqual(h.broker.resolve(id: UUID().uuidString, decision: .allow, source: .click), .dropped(.unknownOrResolved))
        let results = [h.broker.resolve(id: a.perm, decision: .allow, source: .click),
                       h.broker.resolve(id: a.perm, decision: .deny(note: nil), source: .hotkey),
                       h.broker.resolve(id: a.perm, decision: .allow, source: .click)]
        XCTAssertEqual(results.filter { $0 == .applied }.count, 1)
        XCTAssertEqual(Array(results.dropFirst()), [.dropped(.unknownOrResolved), .dropped(.unknownOrResolved)])
        XCTAssertEqual(a.permW.bodies.count, 1); XCTAssertEqual(h.statuses, [.allowed])
        // A card still showing an id from before a re-hold (stale render) cannot reach the new request.
        h.broker.observe(h.ev(.hook(.postToolUse), session: "B", id: "t-B"))
        XCTAssertEqual(h.broker.resolve(id: b.perm, decision: .allow, source: .click), .dropped(.unknownOrResolved))
        XCTAssertTrue(b.questionW.bodies.isEmpty)
    }

    func testPostToolUseForAWithBsToolUseIdDoesNotResolveB() {
        let h = harness(), a = setUp(h, "A"), b = setUp(h, "B")
        XCTAssertEqual(h.broker.pending.first { $0.id == b.perm }?.toolUseId, "t-B")
        h.broker.observe(h.ev(.hook(.postToolUse), session: "A", id: "t-B"))
        h.broker.observe(h.ev(.hook(.postToolUse), session: "A", id: "q-B"))
        h.broker.observe(h.ev(.transcriptToolResult(isError: false), session: "A", id: "t-B"))
        XCTAssertTrue(h.statuses.isEmpty); XCTAssertEqual(h.broker.pending.count, 4)
        h.broker.observe(h.ev(.hook(.postToolUse), session: "A", id: "t-A"))
        XCTAssertEqual(h.statuses, [.handledElsewhere]); XCTAssertEqual(a.permW.bodies, [nil])
        XCTAssertEqual(Set(h.broker.pending.map(\.id)), [a.question, b.perm, b.question])
    }

    func testSubagentStopReleasesOnlyThatAgentInThatSession() {
        let h = harness()
        let a1 = setUp(h, "A", agent: "ag1"), a2 = setUp(h, "A", agent: "ag2"), b1 = setUp(h, "B", agent: "ag1")
        h.broker.observe(h.ev(.hook(.subagentStop), session: "A", agent: "ag1"))
        XCTAssertEqual(h.statuses, [.handledElsewhere, .handledElsewhere])
        XCTAssertEqual(a1.permW.bodies, [nil]); XCTAssertEqual(a1.questionW.bodies, [nil])
        XCTAssertTrue(a2.permW.bodies.isEmpty && a2.questionW.bodies.isEmpty && b1.permW.bodies.isEmpty && b1.questionW.bodies.isEmpty)
        XCTAssertEqual(Set(h.broker.pending.map(\.id)), [a2.perm, a2.question, b1.perm, b1.question])
    }
}
