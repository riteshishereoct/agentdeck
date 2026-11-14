import XCTest
@testable import AgentDeckCore

final class PresenceRulesTests: XCTestCase {
    private let cursor = "com.todesktop.230313mzl4w4u92"
    private func p(_ host: String?, front: String?, idle: Double, _ s: AppSettings = AppSettings()) -> Presence {
        PresenceRules.presence(host: host, snapshot: PresenceSnapshot(frontmostBundleId: front, idleSeconds: idle, at: Make.t0), settings: s)
    }
    func testCursorFrontmostAndActiveIsPresent() { XCTAssertEqual(p(cursor, front: cursor, idle: 5), .present) }
    func testOtherAppFrontmostIsAway() { XCTAssertEqual(p(cursor, front: "com.apple.Safari", idle: 1), .away); XCTAssertEqual(p(cursor, front: nil, idle: 1), .away) }
    func testIdleThresholdIsStrict() {
        XCTAssertEqual(p(cursor, front: cursor, idle: 19.9), .present); XCTAssertEqual(p(cursor, front: cursor, idle: 20), .away)
        var s = AppSettings(); s.awayThresholdSeconds = 60; XCTAssertEqual(p(cursor, front: cursor, idle: 30, s), .present)
    }
    func testAwayModeForcesAwayAndNilHostIsAway() {
        var s = AppSettings(); s.awayMode = true; XCTAssertEqual(p(cursor, front: cursor, idle: 0, s), .away)
        XCTAssertEqual(p(nil, front: cursor, idle: 0), .away)
    }
    func testAnyConfiguredCursorBundleIdMatchesAnyCursorBundleId() {
        var s = AppSettings(); s.cursorBundleIds = [cursor, "com.todesktop.other"]
        XCTAssertEqual(p("com.todesktop.other", front: cursor, idle: 1, s), .present)
        XCTAssertEqual(p(cursor, front: "com.todesktop.other", idle: 1, s), .present)
    }
    func testNonCursorHostIsPresentOnlyWhenItselfIsFrontmost() {
        XCTAssertEqual(p("com.googlecode.iterm2", front: "com.googlecode.iterm2", idle: 1), .present)
        XCTAssertEqual(p("com.googlecode.iterm2", front: cursor, idle: 1), .away)
    }
}
