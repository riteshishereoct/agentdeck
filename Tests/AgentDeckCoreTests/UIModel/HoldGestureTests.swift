import XCTest
@testable import AgentDeckCore

final class HoldGestureTests: XCTestCase {
    func testCompletesOnlyAfterOneSecond() {
        let c = FakeClock(); var h = HoldGesture(clock: c)
        h.begin(requestId: "H"); c.advance(0.999)
        XCTAssertEqual(h.progress(), 0.999, accuracy: 0.001)
        XCTAssertNil(h.complete()); XCTAssertNil(h.requestId)
        h.begin(requestId: "H"); c.advance(1.0)
        XCTAssertEqual(h.complete(), "H"); XCTAssertNil(h.requestId)
    }
    func testCancelAndIdleProgress() {
        let c = FakeClock(); var h = HoldGesture(clock: c)
        XCTAssertEqual(h.progress(), 0); h.begin(requestId: "H"); h.cancel(); c.advance(2); XCTAssertNil(h.complete())
    }
}
