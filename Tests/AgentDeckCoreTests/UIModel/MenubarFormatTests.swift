import XCTest
@testable import AgentDeckCore

final class MenubarFormatTests: XCTestCase {
    func testBadge() {
        XCTAssertEqual(MenubarFormat.badge(pending: 0), ""); XCTAssertEqual(MenubarFormat.badge(pending: 3), "3")
        XCTAssertEqual(MenubarFormat.badge(pending: 9), "9"); XCTAssertEqual(MenubarFormat.badge(pending: 10), "9+")
    }
    func testClampAway() {
        XCTAssertEqual(SettingsFormat.clampAway(1), 5); XCTAssertEqual(SettingsFormat.clampAway(20), 20); XCTAssertEqual(SettingsFormat.clampAway(999), 300)
    }
    func testParseBundleIds() {
        XCTAssertEqual(SettingsFormat.parseBundleIds(" a.b, c.d\n a.b ,, e.f ", fallback: ["x"]), ["a.b", "c.d", "e.f"])
        XCTAssertEqual(SettingsFormat.parseBundleIds("  ,\n ", fallback: ["x"]), ["x"])
    }
}
