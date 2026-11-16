import XCTest
@testable import AgentDeckCore

final class ThemeSettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }
    func testOldBlobGetsThemeDefaultsAndKeepsOthers() throws {
        let s = try decode(#"{"quiet":true,"awayThresholdSeconds":45,"gateScope":"full"}"#)
        XCTAssertTrue(s.quiet); XCTAssertEqual(s.awayThresholdSeconds, 45); XCTAssertEqual(s.gateScope, .full)
        XCTAssertEqual(s.appearance, .system); XCTAssertEqual(s.surface, .liquidGlass); XCTAssertEqual(s.accent, .system)
        XCTAssertEqual(s.panelOpacity, 0.82); XCTAssertTrue(s.animatedEmoji); XCTAssertEqual(s.companion, .pet)
    }
    func testRoundTrip() throws {
        var a = AppSettings()
        a.appearance = .dark; a.surface = .solid; a.accent = .sunset; a.panelOpacity = 0.5; a.animatedEmoji = false
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }
    func testOpacityClamping() throws {
        XCTAssertEqual(ThemeFormat.clampOpacity(0), 0.35)
        XCTAssertEqual(ThemeFormat.clampOpacity(5), 1.0)
        XCTAssertEqual(ThemeFormat.clampOpacity(.nan), 0.82)
        XCTAssertEqual(ThemeFormat.clampOpacity(0.6), 0.6)
        XCTAssertEqual(try decode(#"{"panelOpacity":0.01}"#).panelOpacity, 0.35)
    }
    func testUnknownRawValueFallsBackPerField() throws {
        let s = try decode(#"{"quiet":true,"surface":"hologram","accent":"ocean","appearance":7,"panelOpacity":"x"}"#)
        XCTAssertTrue(s.quiet); XCTAssertEqual(s.surface, .liquidGlass); XCTAssertEqual(s.accent, .ocean)
        XCTAssertEqual(s.appearance, .system); XCTAssertEqual(s.panelOpacity, 0.82)
    }
}
