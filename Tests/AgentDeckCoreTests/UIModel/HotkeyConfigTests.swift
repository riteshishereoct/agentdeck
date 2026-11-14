import XCTest
@testable import AgentDeckCore

final class HotkeyConfigTests: XCTestCase {
    let co = Hotkey.control | Hotkey.option
    func testDefaults() {
        let d = HotkeyConfig.defaults
        XCTAssertEqual(d[.toggleExpand], Hotkey(keyCode: 49, modifiers: co)); XCTAssertEqual(d[.allowTop], Hotkey(keyCode: 16, modifiers: co))
        XCTAssertEqual(d[.denyTop], Hotkey(keyCode: 45, modifiers: co)); XCTAssertEqual(d[.openTop], Hotkey(keyCode: 31, modifiers: co))
        XCTAssertEqual(d[.privacy], Hotkey(keyCode: 4, modifiers: co))
        for a in HotkeyAction.allCases { XCTAssertTrue(d[a].includesControl) }
    }
    func testOptionOnlyRejected() {
        XCTAssertThrowsError(try HotkeyConfig.defaults.setting(.allowTop, to: Hotkey(keyCode: 16, modifiers: Hotkey.option))) { XCTAssertEqual($0 as? HotkeyError, .missingControl) }
        XCTAssertThrowsError(try HotkeyConfig.defaults.setting(.allowTop, to: Hotkey(keyCode: 16, modifiers: 0)))
    }
    func testDuplicateRejectedAndValidRebind() throws {
        XCTAssertThrowsError(try HotkeyConfig.defaults.setting(.allowTop, to: Hotkey(keyCode: 45, modifiers: co))) { XCTAssertEqual($0 as? HotkeyError, .duplicate(of: .denyTop)) }
        let c = try HotkeyConfig.defaults.setting(.allowTop, to: Hotkey(keyCode: 0, modifiers: Hotkey.control | Hotkey.shift))
        XCTAssertEqual(c[.allowTop].keyCode, 0)
    }
    func testCarbonModifiers() {
        XCTAssertEqual(HotkeyConfig.carbonModifiers(control: true, option: true, command: false, shift: false), 0x1800)
        XCTAssertEqual(HotkeyConfig.carbonModifiers(control: false, option: false, command: true, shift: true), 0x0300)
    }
    func testStorePersistsUnderHotkeysAndHealsCorruption() throws {
        let n = "adk.test.\(UUID().uuidString)"; let d = UserDefaults(suiteName: n)!; defer { d.removePersistentDomain(forName: n) }
        let st = HotkeyStore(defaults: d)
        XCTAssertEqual(st.load(), .defaults)
        let c = try HotkeyConfig.defaults.setting(.openTop, to: Hotkey(keyCode: 3, modifiers: Hotkey.control | Hotkey.option))
        st.save(c); XCTAssertNotNil(d.data(forKey: "Hotkeys")); XCTAssertEqual(st.load(), c)
        d.set(Data("x".utf8), forKey: "Hotkeys"); XCTAssertEqual(st.load(), .defaults)
        var bad = HotkeyConfig.defaults; bad.bindings["allowTop"] = Hotkey(keyCode: 16, modifiers: Hotkey.option)
        d.set(try JSONEncoder().encode(bad), forKey: "Hotkeys")
        XCTAssertEqual(st.load()[.allowTop], HotkeyConfig.defaults[.allowTop])
    }
}
