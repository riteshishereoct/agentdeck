import AppKit
import SwiftUI

/// Floating, non-activating panel. Never key unless `allowsKey` (a note or question text field is open): anti-goal 1, never steal focus.
final class OverlayPanel: NSPanel {
    var allowsKey = false

    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: content.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        contentView = content
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = false // explicit pill/header drag regions keep layout changes separate from user moves
        isFloatingPanel = true
        level = .statusBar   // isFloatingPanel resets the level; set the final level afterwards.
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click land on a button even though the panel is not key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
