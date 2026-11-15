import XCTest
@testable import AgentDeckCore

final class PillSummaryTests: XCTestCase {
    func testSpecExample() {
        let s = [UI.session("1", state: .needsYou), UI.session("2", state: .working), UI.session("3", state: .working), UI.session("4", state: .idle)]
        XCTAssertEqual(PillSummary.make(s), PillSummary(text: "1 needs you · 2 working · 1 idle", color: .amber))
    }
    func testIdleOnlyEmptyAndEnded() {
        XCTAssertEqual(PillSummary.make([UI.session(state: .idle)]), PillSummary(text: "Idle · 1 session", color: .grey))
        XCTAssertEqual(PillSummary.make([UI.session("1", state: .idle), UI.session("2", state: .quiet)]), PillSummary(text: "Idle · 2 sessions", color: .grey))
        XCTAssertEqual(PillSummary.make([]), PillSummary(text: "No agents", color: .grey))
        XCTAssertEqual(PillSummary.make([UI.session(state: .ended)]).text, "No agents")
    }
    func testNeverCountsIdleChatAsAgent() {
        XCTAssertFalse(PillSummary.make([UI.session(state: .idle)]).text.contains("agent"))
        XCTAssertEqual(PillSummary.make([UI.session("1", state: .working), UI.session("2", state: .quiet)]).text, "1 working · 1 idle")
    }
    func testWaitingInCursorIsActiveNotIdle() {
        XCTAssertEqual(PillSummary.make([UI.session(state: .waitingInCursor)]), PillSummary(text: "1 waiting in Cursor", color: .amber))
    }
    func testColorPriorityAndOrder() {
        XCTAssertEqual(PillSummary.make([UI.session("1", state: .working), UI.session("2", state: .yourTurn)]).color, .green)
        XCTAssertEqual(PillSummary.make([UI.session("1", state: .yourTurn), UI.session("2", state: .error)]).color, .red)
        XCTAssertEqual(PillSummary.make([UI.session("1", state: .working)]).color, .blue)
        XCTAssertEqual(PillSummary.make([UI.session("1", state: .error), UI.session("2", state: .yourTurn), UI.session("3", state: .working)]).text,
                       "1 error · 1 ready for you · 1 working")
    }
}
