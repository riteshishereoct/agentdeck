import XCTest
@testable import AgentDeckCore

final class OverlayVisibilityTests: XCTestCase {
    private func show(_ v: inout OverlayVisibility, _ s: [Session] = [], cards: Bool = false, hover: Bool = false, hide: Bool = true) -> Bool {
        v.shouldShow(sessions: s, cardsVisible: cards, hovering: hover, hideWhenIdle: hide)
    }
    func testIdleHidesActiveShows() {
        var v = OverlayVisibility()
        XCTAssertFalse(show(&v))
        XCTAssertFalse(show(&v, [UI.session(state: .idle), UI.session("2", state: .quiet), UI.session("3", state: .yourTurn), UI.session("4", state: .ended)]))
        for st in [SessionState.working, .needsYou, .error, .waitingInCursor] {
            var w = OverlayVisibility()
            XCTAssertTrue(show(&w, [UI.session(state: st)]), "\(st)")
        }
    }
    func testPendingRequestCardAndHoverShow() {
        var v = OverlayVisibility()
        XCTAssertTrue(show(&v, [UI.session(state: .idle, pending: [UI.request("A")])]))
        var r = OverlayVisibility()
        XCTAssertFalse(show(&r, [UI.session(state: .idle, pending: [UI.request("A", status: .handledElsewhere)])]))
        XCTAssertTrue(show(&r, cards: true))
        XCTAssertTrue(show(&r, hover: true))
        XCTAssertFalse(show(&r))
    }
    func testRevealStaysUntilActiveToIdleTransition() {
        var v = OverlayVisibility()
        v.reveal()
        XCTAssertTrue(show(&v))                                    // idle but revealed
        XCTAssertTrue(show(&v))
        XCTAssertTrue(show(&v, [UI.session(state: .working)]))     // becomes active
        XCTAssertFalse(show(&v, [UI.session(state: .idle)]))       // active -> idle clears the reveal
        XCTAssertFalse(show(&v))
    }
    func testSettingOffNeverHides() {
        var v = OverlayVisibility()
        XCTAssertTrue(show(&v, hide: false))
    }
    func testUserHideSuppressesUntilRevealOrNewActivity() {
        var v = OverlayVisibility()
        XCTAssertTrue(show(&v, [UI.session(state: .working)]))
        v.userHide()
        XCTAssertFalse(show(&v, [UI.session(state: .working)]))
        XCTAssertFalse(show(&v, [UI.session(state: .working)], hide: false))
        v.reveal()
        XCTAssertTrue(show(&v, [UI.session(state: .working)]))
        v.userHide()
        XCTAssertFalse(show(&v, [UI.session(state: .working)]))
        _ = show(&v, [UI.session(state: .idle)])
        XCTAssertTrue(show(&v, [UI.session(state: .working)]))     // new activity re-shows
    }
}
