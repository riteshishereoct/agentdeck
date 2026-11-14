import Foundation
import CoreGraphics

public struct QueueContext: Equatable {
    public var expanded: Bool; public var quiet: Bool; public var privacy: Bool
    public var mutedIds: Set<String>      // channel-1 requests while presence == .present
    public var cardFullyVisible: Bool
    public var cardFrame: CGRect?          // top card's on-screen frame as drawn; any change restarts arming (F-SHIFT)
    public var cwds: [String: String]      // sessionId -> workspace folder, for SuggestionScope
    public var collapsedIds: Set<String>
    public var revealedId: String?        // a muted row the user expanded (first hotkey press / click)
    public var noteEditingId: String?     // request whose Deny note editor is open: the Deny hotkey must not drop that draft
    public init(expanded: Bool = false, quiet: Bool = false, privacy: Bool = false, mutedIds: Set<String> = [], revealedId: String? = nil, cardFullyVisible: Bool = true, cardFrame: CGRect? = nil, cwds: [String: String] = [:], collapsedIds: Set<String> = [], noteEditingId: String? = nil) {
        self.collapsedIds = collapsedIds; self.noteEditingId = noteEditingId
        self.cardFullyVisible = cardFullyVisible; self.cardFrame = cardFrame; self.cwds = cwds
        self.expanded = expanded; self.quiet = quiet; self.privacy = privacy; self.mutedIds = mutedIds; self.revealedId = revealedId
    }
}

public enum CardAction: Equatable { case allow, deny(note: String?), answer([String: String]), allowAlways(JSONValue) }
public enum ActionTrigger: Equatable { case click, hotkey, hold }
public enum CardDrop: String, Equatable { case noCard, staleCard, notArmed, personOnly, needsHold, highRiskHotkey, notApplicable, noteOpen }
public enum ActionOutcome: Equatable {
    case send(requestId: String, decision: Decision, source: DecisionSource)
    case expandOnly(revealId: String?)
    case dropped(CardDrop)
}

public struct ClosedCard: Equatable { public let requestId: String; public let text: String; public let since: Date }

/// Single source of truth for which card is on screen and whether Allow may fire. Main-thread only.
public final class CardQueue {
    public static let armDelay: TimeInterval = 0.6
    public static let closedTTL: TimeInterval = 3
    private let clock: Clock
    public init(clock: Clock) { self.clock = clock }

    public private(set) var ordered: [Request] = []
    public private(set) var renderedId: String?
    private var context = QueueContext()
    private var lastPending: [Request] = []
    private var showingId: String?      // top id while it is showing, as of the last sync
    private var shownId: String?        // id whose render started the arm clock
    private var shownSince: Date?
    private var applied: Set<String> = []
    public private(set) var closed: [ClosedCard] = []

    public var top: Request? { ordered.first }
    /// The top request only while its card is on screen (expanded, not quiet/private, not muted unless revealed).
    public var showingTop: Request? { ordered.first.flatMap { $0.id == showingId ? $0 : nil } }
    private var arrival: [Request] = []   // pending, oldest first; `ordered` is this with the picked request moved to the front
    private var topArrivalIndex: Int? { top.flatMap { t in arrival.firstIndex { $0.id == t.id } } }
    public var positionText: String? { arrival.count > 1 ? "\((topArrivalIndex ?? 0) + 1) of \(arrival.count)" : nil }
    /// The next pending request in arrival order after the one shown (wraps), for the card's Next control.
    public var nextId: String? { arrival.count > 1 ? arrival[((topArrivalIndex ?? 0) + 1) % arrival.count].id : nil }
    public var isArmed: Bool {
        guard context.cardFullyVisible, let s = shownSince else { return false }
        return clock.now().timeIntervalSince(s) >= Self.armDelay - 0.000_001
    }

    /// No repeating UI clock is needed once a stable card is armed or collapsed.
    public var nextWakeAt: Date? {
        let now = clock.now()
        var dates = closed.map { $0.since.addingTimeInterval(Self.closedTTL) }
        if !isArmed, let shownSince { dates.append(shownSince.addingTimeInterval(Self.armDelay)) }
        return dates.filter { $0 > now }.min()
    }

    private func isShowing(_ r: Request, _ c: QueueContext) -> Bool {
        c.expanded && !c.quiet && !c.privacy && !c.collapsedIds.contains(r.id) && (!c.mutedIds.contains(r.id) || c.revealedId == r.id)
    }

    @discardableResult
    public func sync(pending: [Request]? = nil, context: QueueContext) -> [Request] {
        if let p = pending { lastPending = p }
        let previous = Set(ordered.map(\.id)), previousFrame = self.context.cardFrame
        arrival = lastPending.filter { $0.status == .pending }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        ordered = arrival
        // The request the person picked (row, chevron or Next) is the one shown and decided; the rest keep arrival order.
        if let f = context.revealedId, let i = ordered.firstIndex(where: { $0.id == f }), i > 0 { ordered.insert(ordered.remove(at: i), at: 0) }
        self.context = context
        noteClosed(previousOrdered: previous)
        let newShowing = ordered.first.flatMap { isShowing($0, context) ? $0.id : nil }
        // Arming restarts at the next render when the card changes, is clipped, or moves/resizes under the pointer.
        if newShowing != showingId || !context.cardFullyVisible || context.cardFrame != previousFrame { shownId = nil; shownSince = nil }
        showingId = newShowing
        return ordered.filter { !previous.contains($0.id) }
    }

    /// Our own successful resolve: no closed card.
    public func noteApplied(requestId: String) {
        applied.insert(requestId); closed.removeAll { $0.requestId == requestId }
    }

    public func visibleClosed() -> [ClosedCard] {
        let now = clock.now()
        return closed.filter { now.timeIntervalSince($0.since) < Self.closedTTL }
    }

    // A request that was queued and is now gone (or non-pending with a status line) leaves a 3 s closed card.
    private func noteClosed(previousOrdered previous: Set<String>) {
        let now = clock.now()
        closed.removeAll { now.timeIntervalSince($0.since) >= Self.closedTTL }
        let byId = Dictionary(lastPending.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for id in previous where !ordered.contains(where: { $0.id == id }) {
            if applied.remove(id) != nil { continue }
            let text = byId[id].map { StatusText.text(for: $0.status) } ?? "Handled elsewhere"
            if let text { closed.append(ClosedCard(requestId: id, text: text, since: now)) }
        }
    }

    /// The view reports the card it actually drew; Allow arms 600 ms from here, not from `sync`.
    public func didRender(topId: String?) {
        renderedId = topId
        if context.cardFullyVisible, let id = topId, id == showingId, id != shownId { shownId = id; shownSince = clock.now() }
    }

    public func perform(_ action: CardAction, renderedId: String?, via: ActionTrigger) -> ActionOutcome {
        guard let top = ordered.first else { return .dropped(.noCard) }
        let muted = context.mutedIds.contains(top.id) && context.revealedId != top.id
        if context.collapsedIds.contains(top.id) { return .dropped(.notArmed) }
        if via == .hotkey, !isShowing(top, context) { return .expandOnly(revealId: muted ? top.id : nil) }
        guard isShowing(top, context), renderedId == top.id else { return .dropped(.staleCard) }
        if top.channel == .notify { return .dropped(.notApplicable) }
        let source: DecisionSource = via == .hotkey ? .hotkey : via == .click ? .click : .holdConfirmed
        switch action {
        case .deny(let note):
            // The hotkey only stands in for a Deny button the card actually shows, and never discards an open note draft.
            if via == .hotkey, !CardLayout.buttons(for: top).contains(.deny) { return .dropped(.notApplicable) }
            if via == .hotkey, context.noteEditingId == top.id { return .dropped(.noteOpen) }
            if !isArmed { return .dropped(.notArmed) }   // L1: a late click or a note sent after a resize must not land on a card not seen for 600 ms
            return .send(requestId: top.id, decision: .deny(note: note), source: source)
        case .answer(let answers):
            guard top.kind == .question, top.hook == .preToolUse, top.channel == .gate, via == .click else { return .dropped(.notApplicable) }
            if top.personOnly { return .dropped(.personOnly) }
            if !isArmed { return .dropped(.notArmed) }
            let specs = QuestionForm.parse(top.fullInput)
            guard !specs.isEmpty, Set(answers.keys) == Set(specs.map(\.question)),
                  answers.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return .dropped(.notApplicable) }
            return .send(requestId: top.id, decision: .answer(answers), source: .click)
        case .allowAlways(let suggestion):
            guard top.kind == .permission, top.hook == .permissionRequest, top.channel == .race,
                  top.suggestions.contains(suggestion), via != .hotkey else { return .dropped(.notApplicable) }
            if top.personOnly { return .dropped(.personOnly) }
            if !isArmed { return .dropped(.notArmed) }
            if CardLayout.allowNeedsHold(top) || SuggestionScope.needsHold(suggestion, cwd: context.cwds[top.sessionId]), via != .hold {
                return .dropped(.needsHold)
            }
            return .send(requestId: top.id, decision: .allowAlways(suggestion: suggestion), source: source)
        case .allow:
            guard top.kind == .permission else { return .dropped(.notApplicable) }
            if top.personOnly { return .dropped(.personOnly) }
            if !isArmed { return .dropped(.notArmed) }
            if CardLayout.allowNeedsHold(top) {
                if via == .hotkey { return .dropped(.highRiskHotkey) }
                if via == .click { return .dropped(.needsHold) }
            }
            return .send(requestId: top.id, decision: .allow, source: source)
        }
    }
}

/// M4: an "Allow always" suggestion whose scope outlives this request in a broad way must be confirmed with a hold, at any risk.
public enum SuggestionScope {
    /// Broad: any setMode; a userSettings/projectSettings destination; addDirectories outside `cwd` (or cwd unknown);
    /// anything malformed or of an unknown type (fail safe).
    public static func needsHold(_ suggestion: JSONValue, cwd: String?) -> Bool {
        guard case .object(let o) = suggestion, case .string(let type)? = o["type"] else { return true }
        if case .string(let d)? = o["destination"], d == "userSettings" || d == "projectSettings" { return true }
        switch type {
        case "addRules", "replaceRules", "removeRules", "removeDirectories": return false
        case "addDirectories":
            guard let cwd, case .array(let dirs)? = o["directories"], !dirs.isEmpty else { return true }
            let root = URL(fileURLWithPath: cwd).standardized.path
            return dirs.contains { d in
                guard case .string(let p) = d, !p.hasPrefix("~") else { return true }
                let full = URL(fileURLWithPath: p.hasPrefix("/") ? p : root + "/" + p).standardized.path
                return full != root && !full.hasPrefix(root + "/")
            }
        default: return true   // setMode and anything new
        }
    }
}
