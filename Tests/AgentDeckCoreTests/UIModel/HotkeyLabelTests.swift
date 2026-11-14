import XCTest
@testable import AgentDeckCore

final class HotkeyLabelTests: XCTestCase {
    func testDefaultsRender() {
        XCTAssertEqual(HotkeyLabel.text(HotkeyConfig.defaults[.allowTop]), "⌃⌥Y")
        XCTAssertEqual(HotkeyLabel.text(HotkeyConfig.defaults[.toggleExpand]), "⌃⌥Space")
    }
    func testAllModifiersOrderAndUnknownKey() {
        let all = Hotkey.control | Hotkey.option | Hotkey.shift | Hotkey.command
        XCTAssertEqual(HotkeyLabel.text(Hotkey(keyCode: 0, modifiers: all)), "⌃⌥⇧⌘A")
        XCTAssertEqual(HotkeyLabel.text(Hotkey(keyCode: 200, modifiers: Hotkey.control)), "⌃key 200")
    }
}
