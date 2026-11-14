import XCTest
@testable import AgentDeckCore

final class RowFormatTests: XCTestCase {
    func testTitle() {
        XCTAssertEqual(RowFormat.title(UI.session(project: "my-project", title: "Fix S3 pool leak", goal: "g")), "my-project · Fix S3 pool leak")
        XCTAssertEqual(RowFormat.title(UI.session(project: "my-project", goal: "do x")), "my-project · do x")
        XCTAssertEqual(RowFormat.title(UI.session(project: "my-project")), "my-project · Goal unavailable")
        XCTAssertEqual(RowFormat.title(UI.session(project: "")), "unknown project · Goal unavailable")
    }
    func testDurations() {
        XCTAssertEqual(RowFormat.sessionAge(59), "<1m"); XCTAssertEqual(RowFormat.sessionAge(240), "4m"); XCTAssertEqual(RowFormat.sessionAge(3900), "1h 05m")
        XCTAssertEqual(RowFormat.stepElapsed(41), "0:41"); XCTAssertEqual(RowFormat.stepElapsed(723), "12:03")
    }
    func testModelLabel() {
        XCTAssertEqual(RowFormat.modelLabel("claude-opus-4-5"), "Opus"); XCTAssertEqual(RowFormat.modelLabel("claude-sonnet-5-5"), "Sonnet")
        XCTAssertEqual(RowFormat.modelLabel("CLAUDE-HAIKU-5"), "Haiku"); XCTAssertEqual(RowFormat.modelLabel("foo"), "foo"); XCTAssertNil(RowFormat.modelLabel(nil))
    }
    func testStateAndStep() {
        let now = UI.t0.addingTimeInterval(1320)
        XCTAssertEqual(RowFormat.stateText(UI.session(state: .idle), now: now), "Idle · awaiting activity")
        XCTAssertEqual(RowFormat.stateText(UI.session(state: .waitingInCursor), now: now), "waiting in Cursor ↗")
        let st = Step(label: "Edit ActivityLog.tsx +18 −2", tool: "Edit", toolUseId: nil, startedAt: now.addingTimeInterval(-41), failed: false)
        XCTAssertEqual(RowFormat.stepLine(UI.session(step: st), now: now), "Now: Edit ActivityLog.tsx +18 −2 (since \(RowFormat.clock(st.startedAt)))")
        XCTAssertNil(RowFormat.stepLine(UI.session(), now: now))
        XCTAssertEqual(RowFormat.stepLine(UI.session(state: .needsYou, step: st), now: now), "Waiting: Edit ActivityLog.tsx +18 −2 (since \(RowFormat.clock(st.startedAt)))")
    }
    func testQuietSessionNeverDisplaysRunningTimerForOldStep() {
        let step = Step(label: "TodoWrite", tool: "TodoWrite", startedAt: UI.t0)   // G-NOW: shown as last observed, never "Now"
        XCTAssertEqual(RowFormat.stepLine(UI.session(state: .quiet, step: step), now: UI.t0.addingTimeInterval(5963)), "Last: TodoWrite (\(RowFormat.clock(UI.t0)))")
    }

    func testRawMarkersNeverHideReadableGoalAndWhitespaceIsNormalized() {
        XCTAssertEqual(RowFormat.title(UI.session(project: "my-project", title: "<pasted_content id=\"f956\">", goal: "Build the hover overlay")), "my-project · Build the hover overlay")
        XCTAssertEqual(RowFormat.title(UI.session(project: "my-project", goal: "<pasted_content id=\"abc\">\n# Build AgentDeck\n</pasted_content>")), "my-project · Build AgentDeck")
        XCTAssertEqual(RowFormat.title(UI.session(project: "my-project", title: "   ", goal: "<pasted_content id=\"x\">")), "my-project · Goal unavailable")
        XCTAssertNil(RowFormat.modelLabel("<synthetic>"))
    }

    func testIdleLabelDoesNotCountTime() {
        let session = UI.session(state: .idle)
        XCTAssertEqual(RowFormat.stateText(session, now: UI.t0), "Idle · awaiting activity")
        XCTAssertEqual(RowFormat.stateText(session, now: UI.t0.addingTimeInterval(9999)), "Idle · awaiting activity")
        XCTAssertEqual(RowFormat.stateText(UI.session(state: .quiet), now: UI.t0), "No recent updates")
    }

}
