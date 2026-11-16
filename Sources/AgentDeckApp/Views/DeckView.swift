import AppKit
import SwiftUI
import AgentDeckCore

extension PillColor {
    var color: Color {
        switch self {
        case .grey: return .gray
        case .blue: return .blue
        case .amber: return .orange
        case .green: return .green
        case .red: return .red
        }
    }
}

struct DeckView: View {
    @ObservedObject var model: DeckModel
    /// Resize grip drags, routed to PanelController (left grip?, phase, pointer delta since mouse-down).
    var onGrip: (Bool, GripPhase, CGVector) -> Void = { _, _, _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // @State, not @StateObject: DeckView must not observe pointer moves; only CompanionHost does.
    @State private var tracker = PointerTracker()
    @State private var listHeight: CGFloat = 0
    @State private var panelSize: CGSize = .zero
    @State private var cardBounds: CardBounds?
    static let footerHeight: CGFloat = 16
    /// The card must fit above the grip strip to count as fully visible.
    private var cardViewport: CGSize { CGSize(width: panelSize.width, height: max(0, panelSize.height - Self.footerHeight)) }

    var body: some View {
        let pill = PillSummary.make(model.sessions)
        Group {
            if model.expanded { expandedBody(pill) } else { collapsedBody(pill) }
        }
        .tint(model.settings.accent.color)
        .coordinateSpace(name: CompanionHost.space)
        .onContinuousHover(coordinateSpace: .named(CompanionHost.space)) { phase in
            if case .active(let p) = phase { tracker.point = p } else { tracker.point = nil }
        }
        .onHover { if !$0 { tracker.point = nil }; model.pointer(inside: $0) }
        .onPreferenceChange(CardBoundsKey.self) { bounds in cardBounds = bounds; reportVisibility() }
        .onChange(of: model.expanded) { _, _ in reportVisibility() }
    }

    private func collapsedBody(_ pill: PillSummary) -> some View {
        HStack(spacing: 8) {
            AttentionDot(color: pill.color.color, pulsing: model.pulsing, glowing: model.glowing)
            let pillState = StateEmoji.pillState(model.sessions)
            if model.settings.companion == .off {
                // The pill is always on screen: only the short-lived, urgent needsYou state may loop here (idle-energy budget).
                StateEmojiView(state: pillState, animated: model.settings.animatedEmoji && model.panelVisible && (pillState == .needsYou || !StateEmoji.for(pillState).continuous))
            } else {
                companion(size: 28)
            }
            Text(pill.text).font(.callout.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, model.settings.companion == .off ? 8 : 5)
        .deckSurface(in: Capsule(style: .continuous), settings: model.settings, interactive: true)
        .contentShape(Capsule())
        .overlay(PillHitTarget { began, activate in model.pillInteraction(began: began, activate: activate) })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Expand AgentDeck, \(pill.text)")
        .accessibilityAction(.default, expandPinned)
    }

    private func expandPinned() { model.expandPanel() }

    /// Fixed-size frame: the companion never changes the pill or panel size while it animates.
    @ViewBuilder private func companion(size: CGFloat) -> some View {
        CompanionHost(tracker: tracker, style: model.settings.companion, mood: CompanionMood.from(sessions: model.sessions),
                      enabled: model.settings.animatedEmoji, visible: model.panelVisible,
                      accent: model.settings.accent.color ?? .accentColor, size: size)
            .allowsHitTesting(false)
    }

    private func reportVisibility() {
        model.reportCardVisibility(id: model.expanded ? cardBounds?.id : nil,
                                   frame: model.expanded ? cardBounds?.frame : nil, viewport: cardViewport)
    }

    private var cardClipped: Bool {
        guard let b = cardBounds, model.queue.showingTop?.id == b.id else { return false }
        return !CardViewport.fullyVisible(b.frame, in: CGRect(origin: .zero, size: cardViewport))
    }

    // The top card sits outside the list's ScrollView: list scrolling or list updates never move it under the pointer.
    private func expandedBody(_ pill: PillSummary) -> some View {
        DeckColumn(listHeight: listHeight, maxHeight: model.maxPanelHeight) {
            header(pill).padding([.horizontal, .top], 12)
            if !model.settings.privacy, let r = model.queue.top,
               model.queue.showingTop?.id == r.id || model.requestPresentation.collapsed.contains(r.id) {
                ActionCardView(model: model, request: r).id(r.id)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: CardBoundsKey.self, value: CardBounds(id: r.id, frame: proxy.frame(in: .named("DeckPanel"))))
                    })
                    .padding(.horizontal, 12)
            }
            ScrollView(.vertical) {
                listContent.padding(.horizontal, 12).padding(.bottom, 4)
                    .background(GeometryReader { proxy in Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height) })
            }
            .scrollIndicators(.visible)
            footer
        }
        .frame(width: model.panelWidth)
        .background(GeometryReader { proxy in Color.clear.preference(key: PanelSizeKey.self, value: proxy.size) })
        .coordinateSpace(name: "DeckPanel")
        .deckSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), settings: model.settings)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onPreferenceChange(ContentHeightKey.self) { listHeight = $0 }
        .onPreferenceChange(PanelSizeKey.self) { panelSize = $0; reportVisibility() }
    }

    private func header(_ pill: PillSummary) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if model.settings.companion != .off { companion(size: 40) }
                AttentionDot(color: pill.color.color, pulsing: model.pulsing, glowing: model.glowing)
                Text(pill.text).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(PillHitTarget { began, activate in model.pillInteraction(began: began, activate: activate) })
            .help("Drag the header to move AgentDeck")
            Menu {
                Toggle(isOn: Binding(get: { model.settings.hoverToOpen }, set: { value in model.update { $0.hoverToOpen = value } })) {
                    Label("Open on hover", systemImage: "cursorarrow.rays")
                }
                Text(model.settings.hoverToOpen ? "Hover to open · drag to move" : "Click to open · drag to move")
                Divider()
                Toggle(isOn: Binding(get: { model.settings.privacy }, set: { value in model.update { $0.privacy = value } })) {
                    Label("Privacy", systemImage: "lock.shield")
                }
                Toggle(isOn: Binding(get: { model.settings.sounds }, set: { value in model.update { $0.sounds = value } })) {
                    Label("Attention sounds", systemImage: "speaker.wave.2")
                }
                Divider()
                Button { model.openSettingsWindow?() } label: { Label("Settings…", systemImage: "gearshape") }
                Button { model.openSettingsWindow?(); model.openSetupHelp() } label: { Label("Setup & Help…", systemImage: "questionmark.circle") }
                Button { model.openAboutWindow?() } label: { Label("About AgentDeck", systemImage: "info.circle") }
            } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).fixedSize().help("Deck controls").accessibilityLabel("Deck controls")
            Button { model.collapsePanel() } label: {
                Image(systemName: "chevron.up").frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Collapse").accessibilityLabel("Collapse AgentDeck")
        }
    }

    // Grips live in their own strip below every row and card, so a resize drag can never hit a row or a card button.
    private var footer: some View {
        HStack(spacing: 4) {
            ResizeGrip(left: true) { onGrip(true, $0, $1) }.frame(width: 14, height: 14)
            Spacer()
            if cardClipped { Text("Enlarge the panel to enable actions").font(.caption2).foregroundStyle(.orange).lineLimit(1) }
            Spacer()
            ResizeGrip(left: false) { onGrip(false, $0, $1) }.frame(width: 14, height: 14)
        }
        .padding(.horizontal, 2)
        .frame(height: Self.footerHeight)
    }

    @ViewBuilder private var listContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.settings.privacy {
                ForEach(model.queue.visibleClosed(), id: \.requestId) { c in
                    Text(c.text).font(.callout).foregroundStyle(.secondary)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardBacking(8, Color.secondary.opacity(0.12)))
                        .transition(cardTransition)
                }
                let muted = model.mutedIds
                ForEach(model.queue.ordered.filter { muted.contains($0.id) && model.revealedId != $0.id && !model.requestPresentation.collapsed.contains($0.id) }) { r in
                    Button { model.expandRequest(r.id) } label: {
                        HStack {
                            Text("\(CardFormat.displayTool(r.tool)) · #\(String(r.sessionId.prefix(6))) · answer in Cursor").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").frame(width: 24, height: 24)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Show this request").accessibilityLabel("Show \(CardFormat.displayTool(r.tool)) request from session \(String(r.sessionId.prefix(6)))")
                    .background(cardBacking(8, Color.orange.opacity(0.12)))
                    .transition(cardTransition)
                }
                ForEach(model.completionCards, id: \.sessionId) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("✓ Done").font(.callout.weight(.semibold))
                        Text(card.text).font(.caption).lineLimit(2)
                        HStack {
                            Button("Open ↗") { model.openInCursor(sessionId: card.sessionId) }
                            Button("Dismiss") { model.dismissCompletion(sessionId: card.sessionId) }
                        }
                    }.padding(8).background(cardBacking(8, Color.green.opacity(0.12)))
                    .transition(cardTransition)
                }
                Divider()
                ForEach(model.sessions.filter { $0.state != .ended }) { s in SessionRow(session: s, onOpen: { model.openInCursor(sessionId: s.id) },
                    onCheckHooks: { model.daemon.checkHookHealth(sessionId: s.id) },
                    onRepairHooks: { completion in model.daemon.repairHooks(completion: completion) }, animated: model.settings.animatedEmoji && model.panelVisible) }
            } else {
                ForEach(Array(model.sessions.enumerated()).filter { $0.element.state != .ended }, id: \.element.id) { index, session in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PrivacyFormat.row(index: index + 1, session: session)).font(.caption)
                            Text(RowFormat.sourceLabel(session)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Open session ↗") { model.openInCursor(sessionId: session.id) }.font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardTransition: AnyTransition { reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96)) }
    /// Inner cards keep a material backing so text stays legible over transparent surfaces.
    private func cardBacking(_ radius: CGFloat, _ tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack { shape.fill(.thinMaterial); shape.fill(tint) }
    }
}

/// Only the minimized pill uses this hit target; its mouse sequence cannot reach approval buttons.
private struct PillHitTarget: NSViewRepresentable {
    let onInteraction: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> PillHitView { let view = PillHitView(); view.onInteraction = onInteraction; return view }
    func updateNSView(_ view: PillHitView, context: Context) { view.onInteraction = onInteraction }
}

final class PillHitView: NSView {
    var onInteraction: (Bool, Bool) -> Void = { _, _ in }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var gesture = PillGesture()
        let start = window.convertPoint(toScreen: event.locationInWindow)
        let origin = window.frame.origin
        gesture.begin(at: start)
        onInteraction(true, false)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = window.convertPoint(toScreen: next.locationInWindow)
            _ = gesture.move(to: point)
            if gesture.dragging {
                window.setFrameOrigin(CGPoint(x: origin.x + point.x - start.x, y: origin.y + point.y - start.y))
            }
            if next.type == .leftMouseUp { onInteraction(false, gesture.end()); return }
        }
        onInteraction(false, false)
    }
}

/// Subviews: header, optional top card, list ScrollView, footer.
/// Natural height = header + card ideal + list content + footer, capped at the user's height. When capped, the card keeps up to
/// its ideal height (a concrete proposal, so its own scroll box shrinks and its buttons stay) and the list gets the rest.
private struct DeckColumn: Layout {
    var listHeight: CGFloat
    var maxHeight: CGFloat
    var spacing: CGFloat = 8

    private func ideal(_ v: LayoutSubview, _ w: CGFloat) -> CGFloat { v.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? PanelGeometry.defaultWidth
        let listIndex = subviews.count - 2
        let natural = subviews.indices.reduce(spacing * CGFloat(subviews.count - 1)) { $0 + ($1 == listIndex ? listHeight : ideal(subviews[$1], w)) }
        return CGSize(width: w, height: min(max(60, natural), maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 3 else { return }
        let w = bounds.width, header = subviews[0], list = subviews[subviews.count - 2], footer = subviews[subviews.count - 1]
        let hH = ideal(header, w), fH = ideal(footer, w)
        var y = bounds.minY
        header.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: w, height: hH))
        y += hH + spacing
        var avail = max(0, bounds.height - hH - fH - spacing * CGFloat(subviews.count - 1))
        if subviews.count == 4 {
            let cH = min(ideal(subviews[1], w), avail)
            subviews[1].place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: w, height: cH))
            y += cH + spacing; avail -= cH
        }
        list.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: w, height: avail))
        footer.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - fH), proposal: ProposedViewSize(width: w, height: fH))
    }
}

enum GripPhase { case began, changed, ended }

/// AppKit grip: never moves the window (mouseDownCanMoveWindow false), takes the first click on the non-key panel,
/// and never asks for key status. Reports the pointer delta in screen points since mouse-down.
private struct ResizeGrip: NSViewRepresentable {
    let left: Bool
    let onDrag: (GripPhase, CGVector) -> Void
    func makeNSView(context: Context) -> GripNSView { let v = GripNSView(); v.left = left; v.onDrag = onDrag; return v }
    func updateNSView(_ v: GripNSView, context: Context) { v.left = left; v.onDrag = onDrag }
}

final class GripNSView: NSView {
    var left = false
    var onDrag: (GripPhase, CGVector) -> Void = { _, _ in }
    private var start: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // activeAlways: the panel is never key, so cursor rects alone would not apply.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    // shortcut: no public diagonal resize cursor in this SDK, so crosshair; switch when one is available.
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseDown(with event: NSEvent) {
        start = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        onDrag(.began, .zero)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let s = start else { return }
        let p = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        onDrag(.changed, CGVector(dx: p.x - s.x, dy: p.y - s.y))
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); start = nil; onDrag(.ended, .zero) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let path = NSBezierPath(); path.lineWidth = 1.2
        for i in 1...3 {   // three diagonal ridges pointing at the bottom corner
            let d = CGFloat(i) * 4
            if left { path.move(to: NSPoint(x: 1, y: d)); path.line(to: NSPoint(x: d, y: 1)) }
            else { path.move(to: NSPoint(x: bounds.maxX - 1, y: d)); path.line(to: NSPoint(x: bounds.maxX - d, y: 1)) }
        }
        path.stroke()
    }
}

private struct AttentionDot: View {
    let color: Color
    let pulsing: Bool
    let glowing: Bool
    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .shadow(color: glowing ? .orange : .clear, radius: 5)
            // Keep attention visible without a continuous animation while the user is away.
            .overlay(Circle().stroke(color.opacity(pulsing ? 0.5 : 0), lineWidth: 2).padding(-2))
    }
}

private struct CardBounds: Equatable { let id: String; let frame: CGRect }
private struct CardBoundsKey: PreferenceKey {
    static var defaultValue: CardBounds? = nil
    static func reduce(value: inout CardBounds?, nextValue: () -> CardBounds?) { value = nextValue() ?? value }
}
private struct PanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0 && next.height > 0 { value = next }
    }
}
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 60
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
