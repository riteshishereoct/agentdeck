import XCTest
@testable import AgentDeckCore

final class RequestPresentationTests: XCTestCase {
    func testCollapseAndRefreshPreserveDraftsUntilResolution() {
        var state = RequestPresentation()
        state.collapsed.insert("A"); state.notes["A"] = "use safer command"
        state.questions["A"] = QuestionSelection(other: ["Color?": "green"])
        state.editingOther["A"] = ["Color?"]
        state.retain(pending: ["A", "B"])
        XCTAssertTrue(state.collapsed.contains("A")); XCTAssertFalse(state.collapsed.contains("B"))
        XCTAssertEqual(state.notes["A"], "use safer command")
        XCTAssertEqual(state.questions["A"]?.other["Color?"], "green")
        state.collapsed.remove("A")
        XCTAssertEqual(state.questions["A"]?.other["Color?"], "green")
        state.retain(pending: ["B"])
        XCTAssertTrue(state.notes.isEmpty); XCTAssertTrue(state.questions.isEmpty); XCTAssertTrue(state.editingOther.isEmpty)
    }
    func testCollapsedRequestNeverResolvesAndFreshReopenMustArm() {
        let clock = FakeClock()
        let queue = CardQueue(clock: clock)
        queue.sync(pending: [UI.request("A"), UI.request("B")], context: QueueContext(expanded: true, collapsedIds: ["A"]))
        queue.didRender(topId: "A")
        XCTAssertNil(queue.showingTop); XCTAssertFalse(queue.isArmed)
        XCTAssertEqual(queue.perform(.allow, renderedId: "A", via: .hotkey), .dropped(.notArmed))
        XCTAssertEqual(queue.perform(.deny(note: nil), renderedId: "A", via: .click), .dropped(.notArmed))
        XCTAssertEqual(queue.ordered.map(\.id), ["A", "B"])
        queue.sync(context: QueueContext(expanded: true)); queue.didRender(topId: "A")
        XCTAssertEqual(queue.perform(.allow, renderedId: "A", via: .click), .dropped(.notArmed))
        clock.advance(0.6)
        XCTAssertEqual(queue.perform(.allow, renderedId: "A", via: .click), .send(requestId: "A", decision: .allow, source: .click))
    }
    func testCollapseKeepsExactDraftAndReopensNoteEditor() {
        var state = RequestPresentation()
        let long = String(repeating: "synthetic draft survives collapse ", count: 20)
        state.notes["A"] = long
        state.collapse("A", noteEditorOpen: true)
        XCTAssertTrue(state.collapsed.contains("A")); XCTAssertEqual(state.notes["A"], long)
        state.retain(pending: ["A"])                       // ticks while collapsed
        XCTAssertTrue(state.expand("A"))                   // editor was open: reopen restores it
        XCTAssertFalse(state.collapsed.contains("A")); XCTAssertEqual(state.notes["A"], long)
        state.collapse("A", noteEditorOpen: false)
        XCTAssertFalse(state.expand("A"))                  // editor was closed: stays closed, text kept
        XCTAssertEqual(state.notes["A"], long)
    }
    func testDraftsAreIsolatedPerRequestAndClearedOnResolve() {
        var state = RequestPresentation()
        state.notes["A"] = "note for A"; state.notes["B"] = "note for B"
        state.questions["A"] = QuestionSelection(other: ["Q?": "other A"])
        state.editingOther["A"] = ["Q?"]
        state.collapse("A", noteEditorOpen: true)
        state.resolved("A")
        XCTAssertNil(state.notes["A"]); XCTAssertNil(state.questions["A"]); XCTAssertNil(state.editingOther["A"])
        XCTAssertFalse(state.noteOpen.contains("A"))
        XCTAssertEqual(state.notes["B"], "note for B")
        state.collapse("B", noteEditorOpen: true)
        state.retain(pending: [])                          // resolved elsewhere
        XCTAssertTrue(state.notes.isEmpty); XCTAssertTrue(state.noteOpen.isEmpty); XCTAssertTrue(state.collapsed.isEmpty)
    }
}
