import XCTest
import Darwin
@testable import AgentDeckCore

/// A SIGKILLed hook leaves its curl holding the wait: the broker must not keep offering a consent that cannot reach Claude.
final class HookLivenessBrokerTests: XCTestCase {
    private func held(_ h: Harness, _ i: HookInput, pid: Int32?, gate: Bool = false) -> (String, FakeWaiter) {
        let id = h.hold(gate ? h.broker.gate(i, meta: ui) : h.broker.decide(i, meta: ui)), w = FakeWaiter()
        XCTAssertTrue(h.broker.attach(id: id, waiter: w, hookPid: pid)); return (id, w)
    }

    func testDeadHookIsHandledElsewhereWithinTwoTicksAndALateAllowIsDropped() {
        let h = Harness([.Bash: .race]); var dead: Set<Int32> = [], died: [String] = []
        h.broker.hookAlive = { !dead.contains($0) }; h.broker.onHookDied = { died.append($0) }
        let (a, wa) = held(h, call("Bash", ["command": "npm i"], session: "s1"), pid: 101)
        let (b, wb) = held(h, call("Bash", ["command": "npm ci"], session: "s2"), pid: 202)
        h.tick(0.1); XCTAssertTrue(h.statuses.isEmpty)
        dead.insert(101)
        h.tick(0.1); h.tick(0.1)                                                  // ≤ 2 ticks
        XCTAssertEqual(h.statuses, [.handledElsewhere]); XCTAssertEqual(wa.bodies, [nil]); XCTAssertEqual(died, [a])
        XCTAssertEqual(h.broker.resolve(id: a, decision: .allow, source: .click), .dropped(.unknownOrResolved))
        XCTAssertTrue(wb.bodies.isEmpty); XCTAssertEqual(h.broker.pending.map(\.id), [b])   // the other session is untouched
    }

    func testResolveChecksLivenessFirstSoAClickBeforeTheTickIsDroppedNotApplied() {
        for decision in [Decision.allow, .deny(note: "n")] {
            let h = Harness([.Bash: .race]); var alive = true, died = 0
            h.broker.hookAlive = { _ in alive }; h.broker.onHookDied = { _ in died += 1 }
            let (id, w) = held(h, bash("npm i"), pid: 101)
            alive = false                                                         // dies between ticks
            XCTAssertEqual(h.broker.resolve(id: id, decision: decision, source: .click), .dropped(.unknownOrResolved))
            XCTAssertEqual(w.bodies, [nil]); XCTAssertEqual(h.statuses, [.handledElsewhere]); XCTAssertEqual(died, 1)
        }
    }

    func testOlderHookWithoutPidNeverConsultsLivenessAndStillApplies() {
        let h = Harness([.Bash: .race]); var asked = 0
        h.broker.hookAlive = { _ in asked += 1; return false }
        let (id, w) = held(h, bash("npm i"), pid: nil)
        h.tick(0.1); h.tick(0.1)
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .applied)
        XCTAssertEqual(asked, 0); XCTAssertEqual(h.statuses, [.allowed]); XCTAssertNotNil(w.bodies.first ?? nil)
    }

    func testLiveHookAppliesAndAHeldQuestionIsCoveredToo() {
        let h = Harness([.Bash: .race, .Question: .gate]); h.away(); var alive = true
        h.broker.hookAlive = { _ in alive }
        let (id, _) = held(h, bash("npm i"), pid: 101)
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .applied)
        let q: [String: Any] = ["questions": [["question": "Which?", "header": "Q", "multiSelect": false,
                                               "options": [["label": "A", "description": ""], ["label": "B", "description": ""]]]]]
        let (qid, qw) = held(h, call("AskUserQuestion", q, id: "q1"), pid: 102, gate: true)
        alive = false; h.tick(0.1)
        XCTAssertEqual(h.statuses, [.allowed, .handledElsewhere]); XCTAssertEqual(qw.bodies, [nil])
        XCTAssertEqual(h.broker.resolve(id: qid, decision: .answer(["Which?": "A"]), source: .click), .dropped(.unknownOrResolved))
    }

    func testProcessAliveTreatsGoneAndZombieAsDead() throws {
        XCTAssertTrue(DecisionBroker.processAlive(getpid()))
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, nil), 0)
        XCTAssertTrue(DecisionBroker.processAlive(pid))
        kill(pid, SIGKILL); usleep(100_000)                                       // not reaped yet: a zombie
        XCTAssertFalse(DecisionBroker.processAlive(pid), "a zombie hook is dead")
        var st: Int32 = 0; waitpid(pid, &st, 0)
        XCTAssertFalse(DecisionBroker.processAlive(pid))
    }
}
