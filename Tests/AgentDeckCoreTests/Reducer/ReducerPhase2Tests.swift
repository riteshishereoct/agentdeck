import XCTest
@testable import AgentDeckCore

final class ReducerPhase2Tests: XCTestCase {
    private func run(_ events: [AgentEvent]) -> Session { var s: Session?; for e in events { s = Reducer.apply(s, e) }; return s! }
    private func h(_ k: HookKind, _ at: TimeInterval = 0, agent: String? = nil, type: String? = nil, tool: String? = nil, id: String? = nil,
                   preview: String? = nil, text: String? = nil) -> AgentEvent {
        Make.event(.hook(k), agent: agent, agentType: type, tool: tool, toolUseId: id, preview: preview, text: text, at: Make.t(at))
    }

    func testSubagentStartStopBuildsTheTree() {
        var s = run([h(.userPromptSubmit), h(.subagentStart, 1, agent: "a-1", type: "code-reviewer"), h(.subagentStart, 1, agent: "a-1", type: "code-reviewer")])
        XCTAssertEqual(s.subagents.count, 1); XCTAssertEqual(s.subagents[0].type, "code-reviewer"); XCTAssertEqual(s.subagents[0].state, .working)
        XCTAssertEqual(s.subagents[0].startedAt, Make.t(1))
        s = Reducer.apply(s, h(.subagentStop, 9, agent: "a-1", type: "code-reviewer", text: "Reviewed 3 files.\n\nOk"))
        XCTAssertEqual(s.subagents[0].state, .ended); XCTAssertEqual(s.subagents[0].endedAt, Make.t(9)); XCTAssertEqual(s.subagents[0].summary, "Reviewed 3 files.\nOk")
    }
    func testInternalAgentTypeIsHiddenAndUnknownStopIsIgnored() {
        let s = run([h(.userPromptSubmit), h(.subagentStart, 1, agent: "a-2", type: ""), h(.subagentStop, 2, agent: "a-2", type: ""), h(.subagentStop, 3, agent: "ghost", type: "x")])
        XCTAssertTrue(s.subagents.isEmpty); XCTAssertEqual(s.state, .working)
    }
    func testToolEventsOfAKnownAgentUpdateItsRowNotTheSessionStep() {
        var s = run([h(.userPromptSubmit), h(.preToolUse, 1, tool: "Task", id: "t0", preview: "Agent: code-reviewer"),
                     h(.subagentStart, 2, agent: "a-1", type: "code-reviewer"), h(.preToolUse, 3, agent: "a-1", tool: "Read", id: "t1", preview: "Read x.swift")])
        XCTAssertEqual(s.subagents[0].currentStep?.label, "Read x.swift"); XCTAssertEqual(s.subagents[0].stepCount, 1)
        XCTAssertEqual(s.currentStep?.label, "Agent: code-reviewer"); XCTAssertEqual(s.stepCount, 2)
        s = Reducer.apply(s, h(.postToolUse, 4, agent: "a-1", tool: "Read", id: "t1")); XCTAssertNil(s.subagents[0].currentStep); XCTAssertNotNil(s.currentStep)
        s = Reducer.apply(s, h(.postToolUseFailure, 5, agent: "a-1", tool: "Read", id: "t9")); XCTAssertEqual(s.failureStreak, 0)   // child failures do not count toward the session streak
    }
    func testUnknownAgentIdStillAttachesToTheSession() {
        let s = run([h(.preToolUse, 1, agent: "nobody", tool: "Bash", id: "t1", preview: "Bash: x")])
        XCTAssertEqual(s.currentStep?.label, "Bash: x"); XCTAssertTrue(s.subagents.isEmpty)
    }
    func testEndedSubagentRowsAreCappedAtFifty() {
        var evs = [h(.userPromptSubmit)]
        for i in 0..<60 { evs.append(h(.subagentStart, Double(i * 2 + 1), agent: "a\(i)", type: "t")); evs.append(h(.subagentStop, Double(i * 2 + 2), agent: "a\(i)", type: "t")) }
        let s = run(evs); XCTAssertLessThanOrEqual(s.subagents.count, 50); XCTAssertEqual(s.subagents.last?.id, "a59")
    }
    func testProgressOnlyFromTranscriptTasks() {
        var s = run([h(.userPromptSubmit), h(.preToolUse, 1, tool: "Bash", id: "t1")]); XCTAssertNil(s.progress)
        s = Reducer.apply(s, Make.event(.transcriptTasks(TaskProgress(done: 1, total: 3)), at: Make.t(2))); XCTAssertEqual(s.progress, TaskProgress(done: 1, total: 3))
        s = Reducer.apply(s, Make.event(.transcriptTasks(TaskProgress(done: 0, total: 0)), at: Make.t(3))); XCTAssertNil(s.progress)
    }
    func testTitleAndModelFromTranscript() {
        var s = run([h(.userPromptSubmit)])
        s = Reducer.apply(s, Make.event(.transcriptTitle, text: "Fix S3 pool leak", at: Make.t(1))); XCTAssertEqual(s.title, "Fix S3 pool leak")
        s = Reducer.apply(s, Make.event(.transcriptAssistant, text: "hi", model: "claude-opus-5-5", at: Make.t(2))); XCTAssertEqual(s.model, "claude-opus-5-5")
        s = Reducer.apply(s, Make.event(.transcriptAssistant, text: "again", at: Make.t(3))); XCTAssertEqual(s.model, "claude-opus-5-5")
    }
    func testTranscriptToolResultClearsTheMatchingStepAndWakesQuietOnlyWhenNewer() {
        var s = run([h(.userPromptSubmit), h(.preToolUse, 1, tool: "Bash", id: "t1", preview: "Bash: x")])
        s = Reducer.apply(s, Make.event(.transcriptToolResult(isError: false), toolUseId: "t1", at: Make.t(2))); XCTAssertNil(s.currentStep)
        var q = s; q.state = .quiet
        XCTAssertEqual(Reducer.apply(q, Make.event(.transcriptToolResult(isError: false), toolUseId: "old", at: Make.t(1))).state, .quiet)
        XCTAssertEqual(Reducer.apply(q, Make.event(.transcriptToolResult(isError: false), toolUseId: "new", at: Make.t(99))).state, .working)
    }
    func testActivityBucketsAreThirtyMinutesNewestLast() {
        var s = run([h(.preToolUse, 0, tool: "Bash", id: "a"), h(.preToolUse, 59, tool: "Bash", id: "b")])
        XCTAssertEqual(s.activity.count, 30); XCTAssertEqual(s.activity.last, 2)   // t0 is minute-aligned, so +59 s is the same minute
        s = Reducer.apply(s, h(.preToolUse, 60, tool: "Bash", id: "c")); XCTAssertEqual(Array(s.activity.suffix(2)), [2, 1])
        s = Reducer.apply(s, h(.notification, 180)); XCTAssertEqual(Array(s.activity.suffix(4)), [2, 1, 0, 0])   // any event shifts; only PreToolUse counts
        s = Reducer.apply(s, h(.preToolUse, 180 + 31 * 60, tool: "Bash", id: "d")); XCTAssertEqual(s.activity, Array(repeating: 0, count: 29) + [1])
    }
    func testStoreIgnoresTranscriptEventsForUnknownSessions() {
        let st = SessionStore(); st.apply(Make.event(.transcriptTitle, session: "ghost", text: "x", at: Make.t0)); XCTAssertTrue(st.sessions.isEmpty)
    }
    func testQuietSessionDropsUnconfirmedStepWithoutCompletingTasks() {
        var s = run([h(.userPromptSubmit), h(.preToolUse, 1, tool: "TodoWrite", id: "stale")])
        s.progress = TaskProgress(done: 1, total: 4)
        let active = Reducer.apply(s, Make.event(.tick, at: Make.t(1800)))
        XCTAssertNotNil(active.currentStep)
        s = Reducer.apply(s, Make.event(.tick, at: Make.t(1801)))
        XCTAssertEqual(s.state, .quiet)
        XCTAssertNil(s.currentStep)
        XCTAssertEqual(s.progress, TaskProgress(done: 1, total: 4))
        XCTAssertEqual(s.lastEventAt, Make.t(1))
        s = Reducer.apply(s, Make.event(.transcriptAssistant, text: "resumed", at: Make.t(6000)))
        XCTAssertEqual(s.state, .working)
        XCTAssertNil(s.currentStep)
        s = Reducer.apply(s, h(.preToolUse, 6001, tool: "Read", id: "fresh"))
        XCTAssertEqual(s.currentStep?.toolUseId, "fresh")
        XCTAssertEqual(s.currentStep?.startedAt, Make.t(6001))
    }

}
