import XCTest
@testable import AgentDeckCore

/// A miss = a tool that RAN (non-error tool_result in the transcript) with no PreToolUse of its own within 5 s of the result.
/// Live 2026-11-14 (lead session): later tool_uses of a multi-tool message got their PreToolUse 5-36 s after the tool_use line,
/// when the earlier sibling finished. That is late, not missing, and must never flag.
final class HooksDegradedTests: XCTestCase {
    private func store(launchedAt: Date? = nil, sessions: [String] = ["s1"]) -> SessionStore {
        let st = SessionStore(launchedAt: launchedAt)
        for s in sessions { st.apply(Make.event(.hook(.userPromptSubmit), session: s, at: launchedAt ?? Make.t0)) }
        return st
    }
    private func use(_ st: SessionStore, id: String?, at: TimeInterval, session: String = "s1") {
        st.apply(Make.event(.transcriptToolUse, session: session, tool: "Bash", toolUseId: id, at: Make.t(at)))
    }
    private func result(_ st: SessionStore, id: String, at: TimeInterval, error: Bool = false, session: String = "s1") {
        st.apply(Make.event(.transcriptToolResult(isError: error), session: session, toolUseId: id, at: Make.t(at)))
    }
    private func ran(_ st: SessionStore, id: String, at: TimeInterval, session: String = "s1") {
        use(st, id: id, at: at, session: session); result(st, id: id, at: at + 1, session: session)
    }
    private func tick(_ st: SessionStore, _ at: TimeInterval) { st.apply(Make.event(.tick, session: "", at: Make.t(at))) }
    private func pre(_ st: SessionStore, id: String?, at: TimeInterval, session: String = "s1", agent: String? = nil) {
        st.apply(Make.event(.hook(.preToolUse), session: session, agent: agent, tool: "Bash", toolUseId: id, at: Make.t(at)))
    }
    private func h(_ st: SessionStore, _ s: String = "s1") -> HookHealth { st.sessions[s]!.hookHealth }
    private func degraded(_ st: SessionStore, _ s: String = "s1") -> Bool { st.sessions[s]!.hooksDegraded }

    func testMissingHookFlagsFiveSecondsAfterTheToolRanAndStartsAChecking() {
        let st = store(); ran(st, id: "t1", at: 1)                                   // result at 2
        tick(st, 6.9); XCTAssertFalse(degraded(st))
        tick(st, 7.0); XCTAssertTrue(degraded(st))
        XCTAssertEqual(h(st).state, .checking); XCTAssertEqual(h(st).missed, 1); XCTAssertEqual(h(st).nextCheckAt, Make.t(7))
    }
    func testLateArrivalBeforeTheThresholdNeverFlags() {                              // toolu_01SYcwcD…: 35.7 s behind its sibling
        let st = store(); use(st, id: "queued", at: 1)
        tick(st, 30); XCTAssertFalse(degraded(st))                                    // still waiting behind a long Bash: no result yet
        pre(st, id: "queued", at: 36.7); result(st, id: "queued", at: 37); tick(st, 60)
        XCTAssertFalse(degraded(st)); XCTAssertEqual(h(st).state, .healthy)
    }
    func testLateArrivalAfterTheThresholdResolvesTheMissToHealthy() {
        let st = store(); ran(st, id: "t1", at: 1); tick(st, 8); XCTAssertTrue(degraded(st))
        pre(st, id: "t1", at: 9)
        XCTAssertFalse(degraded(st)); XCTAssertEqual(h(st).missed, 0); XCTAssertEqual(h(st).lastHookAt, Make.t(9))
    }
    func testOutOfOrderPreToolUseBeforeTheTranscriptLineNeverFlags() {
        let st = store(); pre(st, id: "t2", at: 1); ran(st, id: "t2", at: 1.2); tick(st, 20); XCTAssertFalse(degraded(st))
    }
    func testErrorResultsAreNeverMisses() {                                           // validation errors, interrupts, native denials
        let st = store(); use(st, id: "bad", at: 1); result(st, id: "bad", at: 2, error: true); tick(st, 20); XCTAssertFalse(degraded(st))
    }
    func testToolCallsFromBeforeLaunchNeverFlag() {                                   // live 04:37Z: relaunch gap replayed by the tailer
        let st = store(launchedAt: Make.t(10))
        ran(st, id: "gap", at: 9); tick(st, 30); XCTAssertFalse(degraded(st))
        ran(st, id: "live", at: 31); tick(st, 40); XCTAssertTrue(degraded(st))
    }
    func testOldHistoryAfterARestartIsIgnored() {
        let st = store(); tick(st, 7200); ran(st, id: "old", at: 10); tick(st, 7300); XCTAssertFalse(degraded(st))
    }
    func testNilToolUseIdIsIgnored() {
        let st = store(); use(st, id: nil, at: 1); tick(st, 20); XCTAssertFalse(degraded(st))
    }
    func testFreshHookOfTheSameSessionRecoversButKeepsUnresolvedMisses() {
        let st = store(); ran(st, id: "t1", at: 1); tick(st, 8)
        pre(st, id: "t9", at: 9)                                                      // a later tool's PreToolUse: hooks work again
        XCTAssertEqual(h(st).state, .recovered); XCTAssertEqual(h(st).missed, 1); XCTAssertTrue(degraded(st))
        XCTAssertNil(h(st).nextCheckAt, "no timer once recovered")
    }
    func testRecoveryWhileOtherMissesRemainUnresolved() {
        let st = store(); ran(st, id: "t1", at: 1); ran(st, id: "t2", at: 1); tick(st, 8)
        XCTAssertEqual(h(st).missed, 2)
        pre(st, id: "t1", at: 9); XCTAssertEqual(h(st).state, .recovered); XCTAssertEqual(h(st).missed, 1)
        pre(st, id: "t2", at: 10); XCTAssertEqual(h(st).state, .healthy); XCTAssertFalse(degraded(st))
    }
    func testAnotherSessionsHooksNeverClearAndOnlyTheOwnerIsFlagged() {
        let st = store(sessions: ["s1", "s2"]); ran(st, id: "t1", at: 1); tick(st, 10)
        XCTAssertTrue(degraded(st, "s1")); XCTAssertFalse(degraded(st, "s2"))
        pre(st, id: "t1", at: 11, session: "s2")                                      // s2 cannot vouch for s1, even with s1's id
        pre(st, id: "x", at: 12, session: "s2")
        XCTAssertEqual(h(st, "s1").state, .checking); XCTAssertEqual(h(st, "s1").missed, 1)
        XCTAssertEqual(h(st, "s2").lastHookAt, Make.t(12)); XCTAssertNil(h(st, "s1").lastHookAt)
    }
    func testAnotherSessionCannotCancelAPendingMissWithTheSameToolId() {
        let st = store(sessions: ["s1", "s2"])
        use(st, id: "shared", at: 1)
        pre(st, id: "shared", at: 2, session: "s2")
        result(st, id: "shared", at: 3)
        tick(st, 9)
        XCTAssertEqual(h(st, "s1").missed, 1)
        XCTAssertEqual(h(st, "s1").state, .checking)
        XCTAssertEqual(h(st, "s2").state, .healthy)
    }
    func testSubagentPreToolUseCountsForItsSession() {
        let st = store(); use(st, id: "sub1", at: 1); pre(st, id: "sub1", at: 2, agent: "ag1"); result(st, id: "sub1", at: 3)
        tick(st, 20); XCTAssertFalse(degraded(st))
    }
    func testRelaunchWithSnapshotRestoreStartsHealthyAndFlagsOnlyFreshMisses() {
        let st = SessionStore(launchedAt: Make.t(100))
        st.restore([Session(id: "s1", transcriptPath: "/t.jsonl", hooksDegraded: false, startedAt: Make.t0, lastEventAt: Make.t(50))])
        XCTAssertEqual(h(st).state, .healthy)
        ran(st, id: "before", at: 90); tick(st, 110); XCTAssertFalse(degraded(st))    // the previous run's history
        ran(st, id: "fresh", at: 111); tick(st, 120); XCTAssertTrue(degraded(st))
    }
    func testAMissNeverReplaysStepsOrRequests() {
        let st = store(); ran(st, id: "t1", at: 1)
        let before = st.sessions["s1"]!
        tick(st, 8)
        let after = st.sessions["s1"]!
        XCTAssertEqual(after.stepCount, before.stepCount); XCTAssertEqual(after.pending, before.pending)
        XCTAssertEqual(after.currentStep, before.currentStep); XCTAssertEqual(after.lastEventAt, before.lastEventAt)
    }
}
