import XCTest
@testable import AgentDeckCore

final class UsageLabelTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_794_654_100)
    func snap(pct: Double = 58.4, reset: Double = 1_794_657_684, updated: Double = 1_794_654_084) -> UsageSnapshot {
        UsageSnapshot(fiveHour: .init(usedPercentage: pct, resetsAt: reset), updatedAt: updated)
    }
    func hhmm(_ t: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date(timeIntervalSince1970: t))
    }

    func testNilAndMissingWindow() {
        XCTAssertNil(usageLabel(nil, now: now))
        XCTAssertNil(usageLabel(UsageSnapshot(fiveHour: nil, sevenDay: .init(usedPercentage: 1, resetsAt: 2), updatedAt: 0), now: now))
        XCTAssertNil(UsageSnapshot.parse(nil))
        XCTAssertNil(UsageSnapshot.parse(Data("garbage".utf8)))
    }
    func testParseFullAndFiveHourMissing() throws {
        let json = #"{"five_hour":{"used_percentage":58.4,"resets_at":1794657684},"seven_day":{"used_percentage":21,"resets_at":1794744084},"updated_at":1794654084}"#
        let s = try XCTUnwrap(UsageSnapshot.parse(Data(json.utf8)))
        XCTAssertEqual(usageLabel(s, now: now)?.text, "5h 58% · \(hhmm(1_794_657_684))")
        XCTAssertNil(usageLabel(UsageSnapshot.parse(Data(#"{"seven_day":{"used_percentage":1,"resets_at":2},"updated_at":1}"#.utf8)), now: now))
    }
    func testFresh() {
        XCTAssertEqual(usageLabel(snap(), now: now)?.stale, false)
    }
    func testStaleAge() {
        XCTAssertEqual(usageLabel(snap(updated: now.timeIntervalSince1970 - 600), now: now)?.stale, false)
        XCTAssertEqual(usageLabel(snap(updated: now.timeIntervalSince1970 - 601), now: now)?.stale, true)
    }
    func testResetPassed() {
        let l = usageLabel(snap(reset: now.timeIntervalSince1970 - 1), now: now)
        XCTAssertEqual(l?.text, "5h — · reset"); XCTAssertEqual(l?.stale, true)
    }
    func testFloorRounding() {
        XCTAssertTrue(usageLabel(snap(pct: 99.9), now: now)!.text.hasPrefix("5h 99% "))
        XCTAssertTrue(usageLabel(snap(pct: 0.4), now: now)!.text.hasPrefix("5h 0% "))
    }
    func testAccessibility() {
        XCTAssertEqual(usageAccessibility("5h 58% · 14:40"), "Claude plan usage 58 percent, resets 14:40")
        XCTAssertEqual(usageAccessibility("5h — · reset"), "Claude plan usage window reset")
    }
}
