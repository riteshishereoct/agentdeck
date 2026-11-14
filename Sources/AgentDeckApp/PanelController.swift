import AppKit
import Combine
import SwiftUI
import AgentDeckCore

final class PanelController {
    private let model: DeckModel
    private let frames: FrameStore
    private let hosting: FirstMouseHostingView<DeckView>
    private let panel: OverlayPanel
    private var bag = Set<AnyCancellable>()
    private var moveDebounce: DispatchWorkItem?
    /// The user's expanded size (width, and the height cap); the collapsed pill keeps its own fitted size.
    private var userSize = CGSize(width: PanelGeometry.defaultWidth, height: 600)
    /// Stable user placement, independent of SwiftUI's automatic window resizing between model publishes.
    private var userBox: CGRect?
    private var anchorRight = true
    /// While a grip is dragged: the top corner that stays put, and the panel size at mouse-down.
    private var resize: (top: CGPoint, right: Bool, shown: CGSize, user: CGSize)?

    init(model: DeckModel, frames: FrameStore = FrameStore()) {
        self.model = model; self.frames = frames
        hosting = FirstMouseHostingView(rootView: DeckView(model: model))
        panel = OverlayPanel(content: hosting)
        hosting.rootView = DeckView(model: model) { [weak self] left, phase, delta in self?.grip(left: left, phase, delta) }
        place()
        model.panelVisible = false      // nothing is on screen until the model decides to show it
        model.showPanel = { [weak self] in self?.show() }
        model.hidePanel = { [weak self] in self?.hide() }
        model.onPanelMoveEnd = { [weak self] in self?.moved(finished: true) }
        // The panel takes keys only after explicit note or question text entry.
        model.onNoteEditing = { [weak self] open in
            guard let p = self?.panel else { return }
            p.allowsKey = open
            if open { p.makeKey() } else { p.resignKey() }
        }
        model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refit() } }.store(in: &bag)
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            self?.moved()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
        }
    }

    /// Never makeKey / activate: anti-goal 1.
    func show() { model.panelVisible = true; model.refreshUsage(); refit(); panel.orderFrontRegardless() }

    func hide() { model.panelVisible = false; panel.orderOut(nil) }

    private var visible: CGRect { screen(for: panel.frame)?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame }

    /// Pushes the clamped user size into the view, then fits the panel to the view.
    func refit() {
        guard model.panelVisible, !model.pillPressed else { return }
        let v = visible
        let size = PanelGeometry.clamp(userSize, in: v)
        if model.panelWidth != size.width { model.panelWidth = size.width }
        if model.maxPanelHeight != size.height { model.maxPanelHeight = size.height }
        let fit = hosting.fittingSize
        guard fit.width > 0, fit.height > 0 else { return }
        let box = userBox ?? panel.frame
        let target = resize.map { PanelGeometry.anchored(fit, top: $0.top, right: $0.right, in: v) }
            ?? PanelGeometry.anchored(fit, top: CGPoint(x: anchorRight ? box.maxX : box.minX, y: box.maxY), right: anchorRight, in: v)
        // Compare frames, not sizes: SwiftUI may already have grown the window rightwards past the screen edge (live 10:24Z).
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
        publishCorner()
    }

    /// F-SHIFT: the card's screen position includes the panel's; any change disarms it in CardQueue.
    private func publishCorner() { model.panelTopLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY) }

    // Resizing only changes the frame: it never makes the panel key and never reaches rows or card buttons.
    private func grip(left: Bool, _ phase: GripPhase, _ delta: CGVector) {
        let f = panel.frame
        switch phase {
        case .began:
            resize = (CGPoint(x: left ? f.maxX : f.minX, y: f.maxY), left, f.size, userSize)
        case .changed:
            guard let r = resize else { return }
            userSize = PanelGeometry.dragged(user: r.user, shown: r.shown, delta: delta, leftGrip: left, in: visible)
            refit()
        case .ended:
            let right = resize?.right
            resize = nil
            moved(finished: true, right: right)
        }
    }

    private func displayKey(_ s: NSScreen) -> String? {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { SnapGeometry.displayKey($0.uint32Value) }
    }

    private func screen(for frame: CGRect) -> NSScreen? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }
    }

    /// Restores the user box on `s`: size clamped to this display, top edge and near side kept, never off-screen.
    private func restore(_ box: CGRect, on s: NSScreen, right: Bool? = nil) {
        let v = s.visibleFrame
        userSize = PanelGeometry.restoredSize(box.size, in: v)
        model.panelWidth = userSize.width; model.maxPanelHeight = userSize.height
        let fit = hosting.fittingSize
        anchorRight = right ?? (box.midX > v.midX)
        let frame = PanelGeometry.anchored(fit, top: CGPoint(x: anchorRight ? box.maxX : box.minX, y: box.maxY), right: anchorRight, in: v)
        userBox = PanelGeometry.userBox(shown: frame, user: userSize, in: v, right: anchorRight)
        panel.setFrame(frame, display: false)
        publishCorner()
    }

    private func place() {
        for s in NSScreen.screens {
            guard let k = displayKey(s) else { continue }
            if let box = frames.load(displayKey: PanelGeometry.boxKey(k)) { restore(box, on: s, right: frames.loadAnchorRight(displayKey: k)); return }
            // Older builds saved only the shown frame: keep its position, use the default size.
            if let old = frames.load(displayKey: k) {
                restore(PanelGeometry.userBox(shown: old, user: PanelGeometry.restoredSize(nil, in: s.visibleFrame), in: s.visibleFrame), on: s, right: old.midX > s.visibleFrame.midX)
                return
            }
        }
        guard let s = NSScreen.main ?? NSScreen.screens.first else { return }
        userSize = PanelGeometry.restoredSize(nil, in: s.visibleFrame)
        model.panelWidth = userSize.width; model.maxPanelHeight = userSize.height
        let frame = SnapGeometry.defaultFrame(size: hosting.fittingSize, in: s.visibleFrame)
        anchorRight = true
        userBox = PanelGeometry.userBox(shown: frame, user: userSize, in: s.visibleFrame, right: anchorRight)
        panel.setFrame(frame, display: false)
        publishCorner()
    }

    /// Display removed, rearranged or rescaled: stay on the current screen if it still exists, else the nearest one
    /// (its saved box if any); clamp size and position into that screen's visibleFrame.
    private func screensChanged() {
        let screens = NSScreen.screens
        let current = screen(for: panel.frame)
        guard let s = current ?? PanelGeometry.nearest(to: panel.frame, in: screens.map(\.frame)).map({ screens[$0] }) else { return }
        let saved = current == nil ? displayKey(s).flatMap { frames.load(displayKey: PanelGeometry.boxKey($0)) } : nil
        let right = current == nil ? displayKey(s).flatMap { frames.loadAnchorRight(displayKey: $0) } : nil
        restore(saved ?? userBox ?? PanelGeometry.userBox(shown: panel.frame, user: userSize, in: s.visibleFrame), on: s, right: saved != nil ? right : anchorRight)
    }

    /// Remembers the user box (size + top edge + side) for the display the panel is on.
    private func save() {
        guard let s = screen(for: panel.frame), let k = displayKey(s) else { return }
        frames.save(userBox ?? PanelGeometry.userBox(shown: panel.frame, user: userSize, in: s.visibleFrame), displayKey: PanelGeometry.boxKey(k))
        frames.saveAnchorRight(anchorRight, displayKey: k)
    }

    // Debounced 300 ms after the last move: snap to a corner, then remember the box per display. Skipped mid-resize.
    private func moved(finished: Bool = false, right: Bool? = nil) {
        guard model.pillPressed || finished else { return } // intrinsic layout changes are not user moves
        anchorRight = right ?? (panel.frame.midX > visible.midX)
        userBox = PanelGeometry.userBox(shown: panel.frame, user: userSize, in: visible, right: anchorRight)
        publishCorner()
        moveDebounce?.cancel()
        guard resize == nil, !model.pillPressed else { return }
        refit()
        userBox = PanelGeometry.userBox(shown: panel.frame, user: userSize, in: visible, right: anchorRight)
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.resize == nil, !self.model.pillPressed, let s = self.screen(for: self.panel.frame) else { return }
            self.refit()
            let snapped = SnapGeometry.snap(self.panel.frame, in: s.visibleFrame)
            if snapped != self.panel.frame {
                self.panel.setFrame(snapped, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
            self.userBox = PanelGeometry.userBox(shown: snapped, user: self.userSize, in: s.visibleFrame, right: self.anchorRight)
            self.save()
        }
        moveDebounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}
