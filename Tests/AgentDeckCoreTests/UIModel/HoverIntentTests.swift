import XCTest
@testable import AgentDeckCore

final class HoverIntentTests: XCTestCase {
    func testExpandsAfter300ms() {
        let c = FakeClock(); var h = HoverIntent(clock: c)
        h.pointer(inside: true); c.advance(0.299)
        XCTAssertFalse(h.target(expanded: false, pinned: false, hasPending: false))
        c.advance(0.001)
        XCTAssertTrue(h.target(expanded: false, pinned: false, hasPending: false))
    }
    func testQuickPassThroughNeverExpands() {
        let c = FakeClock(); var h = HoverIntent(clock: c)
        h.pointer(inside: true); c.advance(0.2); h.pointer(inside: false); c.advance(5)
        XCTAssertFalse(h.target(expanded: false, pinned: false, hasPending: false))
    }
    func testCollapsesAfter1200msOutside() {
        let c = FakeClock(); var h = HoverIntent(clock: c)
        h.pointer(inside: true); h.pointer(inside: false); c.advance(1.199)
        XCTAssertTrue(h.target(expanded: true, pinned: false, hasPending: false))
        c.advance(0.001)
        XCTAssertFalse(h.target(expanded: true, pinned: false, hasPending: false))
    }
    func testPinnedOrPendingKeepsOpenAndReenterResets() {
        let c = FakeClock(); var h = HoverIntent(clock: c)
        h.pointer(inside: false); c.advance(10)
        XCTAssertTrue(h.target(expanded: true, pinned: true, hasPending: false))
        XCTAssertTrue(h.target(expanded: true, pinned: false, hasPending: true))
        h.pointer(inside: true); c.advance(1); h.pointer(inside: false); c.advance(1)
        XCTAssertTrue(h.target(expanded: true, pinned: false, hasPending: false))
    }
}
