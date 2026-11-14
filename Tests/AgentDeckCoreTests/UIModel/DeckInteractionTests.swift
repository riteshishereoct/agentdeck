import XCTest
@testable import AgentDeckCore

final class DeckInteractionTests: XCTestCase {
    func testClickDefaultAndOldSettingsPreservePrivacy() throws {
        XCTAssertFalse(AppSettings().hoverToOpen)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"privacy":true,"sounds":false}"#.utf8))
        XCTAssertFalse(old.hoverToOpen); XCTAssertTrue(old.privacy); XCTAssertFalse(old.sounds)
        var settings = old; settings.hoverToOpen = true
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testClickModeNeverChangesExpansionFromPointer() {
        let clock = FakeClock(); var hover = HoverIntent(clock: clock)
        hover.pointer(inside: true); clock.advance(5)
        XCTAssertFalse(hover.target(expanded: false, pinned: false, hasPending: true, enabled: false))
        hover.pointer(inside: false); clock.advance(5)
        XCTAssertTrue(hover.target(expanded: true, pinned: false, hasPending: false, enabled: false))
        hover.pointer(inside: true); clock.advance(1)
        XCTAssertTrue(hover.target(expanded: false, pinned: false, hasPending: false, enabled: true))
    }

    func testDragReturningToStartStillIsNotClick() {
        var gesture = PillGesture()
        gesture.begin(at: .zero)
        XCTAssertFalse(gesture.move(to: CGPoint(x: 2, y: 1)))
        XCTAssertTrue(gesture.move(to: CGPoint(x: 5, y: 0)))
        _ = gesture.move(to: .zero)
        XCTAssertFalse(gesture.end())
        gesture.begin(at: .zero)
        _ = gesture.move(to: CGPoint(x: 1, y: 1))
        XCTAssertTrue(gesture.end())
        XCTAssertFalse(gesture.end(), "a stale mouseUp must never open the deck")
    }

    func testStablePendingQueueNeedsOnlyArmingAndExpiryDeadlines() {
        let clock = FakeClock(); let queue = CardQueue(clock: clock)
        queue.sync(pending: [UI.request("waiting")], context: QueueContext(expanded: false))
        XCTAssertNil(queue.nextWakeAt, "collapsed waiting request must not poll")
        queue.sync(context: QueueContext(expanded: true))
        queue.didRender(topId: "waiting")
        XCTAssertEqual(queue.nextWakeAt, clock.now().addingTimeInterval(CardQueue.armDelay))
        clock.advance(CardQueue.armDelay)
        XCTAssertTrue(queue.isArmed); XCTAssertNil(queue.nextWakeAt)
        queue.sync(pending: [], context: QueueContext())
        XCTAssertEqual(queue.nextWakeAt, clock.now().addingTimeInterval(CardQueue.closedTTL))
        clock.advance(CardQueue.closedTTL)
        XCTAssertNil(queue.nextWakeAt)
    }
}
