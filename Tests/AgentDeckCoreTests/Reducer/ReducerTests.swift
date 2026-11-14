import XCTest
@testable import AgentDeckCore

final class ReducerTests: XCTestCase {
    private func run(_ events: [AgentEvent]) -> Session { var s: Session?; for e in events { s = Reducer.apply(s, e) }; return s! }
    private func hook(_ k: HookKind, at: TimeInterval = 0, tool: String? = nil, id: String? = nil, preview: String? = nil, text: String? = nil,
                      nt: String? = nil, agent: String? = nil) -> AgentEvent {
        Make.event(.hook(k), agent: agent, tool: tool, toolUseId: id, preview: preview, text: text, notificationType: nt, at: Make.t(at), pid: 77, host: "h")
    }

    func testFirstEventCreatesIdleSessionWithMetadata() {
        let s = run([hook(.sessionStart)])
        XCTAssertEqual(s.state, .idle); XCTAssertEqual(s.id, "s1"); XCTAssertEqual(s.project, "proj"); XCTAssertEqual(s.cwd, "/Users/me/proj")
        XCTAssertEqual(s.pid, 77); XCTAssertEqual(s.host, "h"); XCTAssertEqual(s.startedAt, Make.t0); XCTAssertEqual(s.lastEventAt, Make.t0)
    }
    func testGoalFromFirstPromptThenLatestAsk() {
        var s = run([hook(.userPromptSubmit, text: "\n  Fix the S3 pool leak\nplease")])
        XCTAssertEqual(s.goal, "Fix the S3 pool leak"); XCTAssertEqual(s.state, .working); XCTAssertNil(s.latestAsk)
        s = Reducer.apply(s, hook(.userPromptSubmit, at: 5, text: "Now add tests"))
        XCTAssertEqual(s.goal, "Fix the S3 pool leak"); XCTAssertEqual(s.latestAsk, "Now add tests")
        let long = run([hook(.userPromptSubmit, text: String(repeating: "a", count: 100))])
        XCTAssertEqual(long.goal?.count, 80); XCTAssertEqual(long.goal?.hasSuffix("…"), true)
    }
    func testFinishedStepBecomesLastStepWithObservedFinishTime() {   // G-NOW
        var s = run([hook(.preToolUse, at: 1, tool: "Bash", id: "t1", preview: "Run regression tests")])
        s = Reducer.apply(s, hook(.postToolUse, at: 9, tool: "Bash", id: "t1"))
        XCTAssertNil(s.currentStep); XCTAssertEqual(s.lastStep?.label, "Run regression tests"); XCTAssertEqual(s.lastStep?.finishedAt, Make.t(9))
        XCTAssertEqual(RowFormat.stepLine(s, now: Make.t(10)), "Last: Run regression tests (\(RowFormat.clock(Make.t(9))))")
        s = Reducer.apply(s, hook(.preToolUse, at: 11, tool: "Read", id: "t2", preview: "Read a.swift"))
        XCTAssertEqual(RowFormat.stepLine(s, now: Make.t(12)), "Now: Read a.swift (since \(RowFormat.clock(Make.t(11))))")
    }
    func testPreToolUseSetsStepAndCountsThenPostClearsOnlyMatching() {
        var s = run([hook(.preToolUse, at: 1, tool: "Bash", id: "t1", preview: "Bash: npm test")])
        XCTAssertEqual(s.state, .working); XCTAssertEqual(s.stepCount, 1)
        XCTAssertEqual(s.currentStep?.label, "Bash: npm test"); XCTAssertEqual(s.currentStep?.tool, "Bash")
        XCTAssertEqual(s.currentStep?.toolUseId, "t1"); XCTAssertEqual(s.currentStep?.startedAt, Make.t(1))
        s = Reducer.apply(s, hook(.postToolUse, at: 2, tool: "Bash", id: "other")); XCTAssertNotNil(s.currentStep)
        s = Reducer.apply(s, hook(.postToolUse, at: 3, tool: "Bash", id: "t1")); XCTAssertNil(s.currentStep); XCTAssertEqual(s.state, .working)
        s = Reducer.apply(s, hook(.preToolUse, at: 4, tool: "Read", id: "t2")); XCTAssertEqual(s.stepCount, 2); XCTAssertEqual(s.currentStep?.label, "Read")
    }
    func testRequestLifecycle() {
        var s = run([hook(.preToolUse, tool: "Bash", id: "t1"), Make.event(.requestHeld(Make.request("r1")), at: Make.t(1))])
        XCTAssertEqual(s.state, .needsYou); XCTAssertEqual(s.pending.map(\.id), ["r1"])
        s = Reducer.apply(s, Make.event(.requestHeld(Make.request("r2")), at: Make.t(2)))
        s = Reducer.apply(s, Make.event(.requestUpdated(id: "r1", status: .allowed), at: Make.t(3)))
        XCTAssertEqual(s.state, .needsYou); XCTAssertEqual(s.pending.map(\.id), ["r2"])
        s = Reducer.apply(s, Make.event(.requestUpdated(id: "r2", status: .movedToCursor), at: Make.t(4)))
        XCTAssertEqual(s.state, .waitingInCursor); XCTAssertEqual(s.pending.first?.status, .movedToCursor)
        s = Reducer.apply(s, Make.event(.requestUpdated(id: "r2", status: .handledElsewhere), at: Make.t(5)))
        XCTAssertEqual(s.state, .working); XCTAssertTrue(s.pending.isEmpty)
        let t = run([Make.event(.requestHeld(Make.request("r3")), at: Make.t(1)), Make.event(.requestUpdated(id: "r3", status: .timedOut), at: Make.t(2))])
        XCTAssertEqual(t.state, .waitingInCursor)
    }
    func testStopSummaryTwoLinesThenPromptClearsIt() {
        var s = run([hook(.preToolUse, tool: "Bash", id: "t1"), hook(.stop, at: 1, text: "Added index.\n\nQuery 4.1s → 180ms.\nThird")])
        XCTAssertEqual(s.state, .yourTurn); XCTAssertEqual(s.summary, "Added index.\nQuery 4.1s → 180ms."); XCTAssertNil(s.currentStep)
        s = Reducer.apply(s, hook(.userPromptSubmit, at: 2, text: "more")); XCTAssertEqual(s.state, .working); XCTAssertNil(s.summary)
    }
    func testIdlePromptNotificationMakesYourTurnButNotOverNeedsYou() {
        XCTAssertEqual(run([hook(.userPromptSubmit), hook(.notification, at: 1, nt: "idle_prompt")]).state, .yourTurn)
        XCTAssertEqual(run([hook(.userPromptSubmit), Make.event(.requestHeld(Make.request()), at: Make.t(1)), hook(.notification, at: 2, nt: "idle_prompt")]).state, .needsYou)
        XCTAssertEqual(run([hook(.userPromptSubmit), hook(.notification, at: 1, nt: "permission_prompt")]).state, .working)
    }
    func testFailureStreakReachesErrorAndResetsOnSuccess() {
        var s = run([hook(.preToolUse, tool: "Bash", id: "t1"), hook(.postToolUseFailure, at: 1, tool: "Bash", id: "t1")])
        XCTAssertEqual(s.state, .working); XCTAssertEqual(s.currentStep?.failed, true)
        s = Reducer.apply(s, hook(.postToolUseFailure, at: 2, tool: "Bash", id: "x")); XCTAssertEqual(s.state, .working)
        s = Reducer.apply(s, hook(.postToolUseFailure, at: 3, tool: "Bash", id: "y"))
        XCTAssertEqual(s.failureStreak, 3); XCTAssertEqual(s.state, .error)
        s = Reducer.apply(s, hook(.postToolUse, at: 4, tool: "Bash", id: "z")); XCTAssertEqual(s.failureStreak, 0); XCTAssertEqual(s.state, .working)
    }
    func testSessionEndAndPidGoneEndTheSessionAndDropPending() {
        for end in [hook(.sessionEnd, at: 5), Make.event(.pidGone, at: Make.t(5))] {
            let s = run([hook(.userPromptSubmit), Make.event(.requestHeld(Make.request()), at: Make.t(1)), end])
            XCTAssertEqual(s.state, .ended); XCTAssertEqual(s.endedAt, Make.t(5)); XCTAssertTrue(s.pending.isEmpty); XCTAssertNil(s.currentStep)
        }
    }
    func testEndedSessionRevivesOnlyOnNewerHookEvents() {
        let ended = run([hook(.userPromptSubmit), hook(.sessionEnd, at: 10)])
        XCTAssertEqual(Reducer.apply(ended, hook(.sessionStart, at: 11)).state, .idle)
        XCTAssertNil(Reducer.apply(ended, hook(.sessionStart, at: 11)).endedAt)
        XCTAssertEqual(Reducer.apply(ended, hook(.preToolUse, at: 12, tool: "Bash", id: "t")).state, .working)
        XCTAssertEqual(Reducer.apply(ended, hook(.postToolUse, at: 9, tool: "Bash", id: "t")).state, .ended)   // late, older than the end
        XCTAssertEqual(Reducer.apply(ended, Make.event(.requestUpdated(id: "r", status: .allowed), at: Make.t(12))).state, .ended)
    }
    func testTickGoesQuietAtExactly1800sWithoutTouchingLastEventAt() {
        let w = run([hook(.userPromptSubmit)])
        XCTAssertEqual(Reducer.apply(w, Make.event(.tick, session: "", at: Make.t(1799))).state, .working)
        let q = Reducer.apply(w, Make.event(.tick, session: "", at: Make.t(1800)))
        XCTAssertEqual(q.state, .quiet); XCTAssertEqual(q.lastEventAt, Make.t0)
        XCTAssertEqual(Reducer.apply(q, hook(.postToolUse, at: 1801, tool: "Bash", id: "t")).state, .working)
        let idle = run([hook(.sessionStart)]); XCTAssertEqual(Reducer.apply(idle, Make.event(.tick, session: "", at: Make.t(9999))).state, .idle)
        let yt = run([hook(.userPromptSubmit), hook(.stop, at: 1, text: "x")]); XCTAssertEqual(Reducer.apply(yt, Make.event(.tick, session: "", at: Make.t(9999))).state, .yourTurn)
    }
    func testOutOfOrderEventsNeverRegressState() {
        var s = run([hook(.userPromptSubmit), hook(.stop, at: 10, text: "done")])
        s = Reducer.apply(s, hook(.postToolUse, at: 8, tool: "Bash", id: "t1"))   // async hook arrives after Stop
        XCTAssertEqual(s.state, .yourTurn); XCTAssertEqual(s.lastEventAt, Make.t(10))
        s = Reducer.apply(s, hook(.preToolUse, at: 5, tool: "Bash", id: "t2", preview: "Bash: x"))   // stale Pre
        XCTAssertEqual(s.stepCount, 1); XCTAssertNil(s.currentStep); XCTAssertEqual(s.state, .yourTurn)
    }
    func testToolEventWithUnknownAgentIdStillAttachesToSession() {
        let s = run([hook(.preToolUse, tool: "Bash", id: "t1", preview: "Bash: x", agent: "a-unknown")])
        XCTAssertEqual(s.stepCount, 1); XCTAssertEqual(s.currentStep?.label, "Bash: x"); XCTAssertEqual(s.state, .working)
    }
    func testToolWorkingDirectoryDoesNotRenameWorkspace() {
        var s = run([hook(.sessionStart)])
        var tool = hook(.preToolUse, at: 1, tool: "Bash", id: "tmp")
        tool.cwd = "/tmp/example/mtest"
        s = Reducer.apply(s, tool)
        XCTAssertEqual(s.project, "proj")
        XCTAssertEqual(s.cwd, "/tmp/example/mtest")
    }

}
