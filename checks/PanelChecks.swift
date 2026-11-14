import AppKit
import SwiftUI

@main
struct PanelChecks {
    static func main() {
        _ = NSApplication.shared
        let panel = OverlayPanel(content: NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 100)))
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        check(panel.level == .statusBar, "overlay must stay at status-bar level after initialization (actual \(panel.level.rawValue), expected \(NSWindow.Level.statusBar.rawValue))")
        check(panel.styleMask.contains(.nonactivatingPanel), "panel must be non-activating")
        check(!panel.canBecomeKey && !panel.canBecomeMain, "ordinary card clicks must not claim keyboard focus")
        panel.allowsKey = true
        check(panel.canBecomeKey, "explicit text entry must be able to receive keyboard focus")
        panel.allowsKey = false
        check(!panel.canBecomeKey, "closing text entry must revoke keyboard focus")
        check(!panel.isMovableByWindowBackground, "only the pill/header drag regions may move the panel")
        check(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]), "panel must support all spaces and full-screen auxiliary placement")
        check(!panel.isVisible, "module checks must not show a window")
        print("PASS: panel level, nonactivation, focus gate, drag and space configuration; no window shown")
    }
}
