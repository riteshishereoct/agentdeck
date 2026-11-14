import XCTest
@testable import AgentDeckCore

final class ClosedCardTests: XCTestCase {
    let open = QueueContext(expanded: true)
    func testStatusTexts() {
        XCTAssertEqual(StatusText.text(for: .handledElsewhere), "Handled elsewhere")
        XCTAssertEqual(StatusText.text(for: .movedToCursor), "Moved to Cursor ↗")
        XCTAssertEqual(StatusText.text(for: .timedOut), "waiting in Cursor ↗")
        XCTAssertNil(StatusText.text(for: .allowed)); XCTAssertNil(StatusText.text(for: .hookGone))
    }
    func testVanishedRequestBecomesHandledElsewhereThenExpires() {
        let c = FakeClock(); let q = CardQueue(clock: c)
        _ = q.sync(pending: [UI.request("A")], context: open)
        _ = q.sync(pending: [], context: open)
        XCTAssertEqual(q.visibleClosed().map(\.text), ["Handled elsewhere"])
        c.advance(2.999); XCTAssertEqual(q.visibleClosed().count, 1)
        c.advance(0.002); XCTAssertTrue(q.visibleClosed().isEmpty)
    }
    func testMovedToCursorStatusAndAppliedSuppression() {
        let c = FakeClock(); let q = CardQueue(clock: c)
        _ = q.sync(pending: [UI.request("A"), UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open)
        q.noteApplied(requestId: "B")
        _ = q.sync(pending: [UI.request("A", status: .movedToCursor)], context: open)
        XCTAssertEqual(q.visibleClosed().map(\.text), ["Moved to Cursor ↗"])   // A shown, B (applied by us) not
    }
}
