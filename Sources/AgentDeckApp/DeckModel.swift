import AppKit
import Combine
import AgentDeckCore

final class DeckModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published private(set) var setupStatus: String?
    @Published private(set) var installingHooks = false
    @Published var settings: AppSettings
    var snapshot: PresenceSnapshot? {
        didSet { if mutedIds(using: oldValue) != mutedIds { tick() } }
    }
    @Published var expanded = false
    @Published var cardNotice: (id: String, text: String)?   // inline drop reason, auto-clears (one-shot)
    private var cardNoticeWork: DispatchWorkItem?
    @Published var pinned = false
    @Published var maxPanelHeight: CGFloat = 600
    @Published var panelWidth: CGFloat = PanelGeometry.defaultWidth   // user's expanded width, set by PanelController
    private var fullyVisibleRequestId: String?
    @Published var requestPresentation = RequestPresentation()
    @Published var revealedId: String?
    @Published var hotkeyConfig = HotkeyConfig.defaults
    @Published var hotkeyFailures: [HotkeyAction: OSStatus] = [:]   // non-zero RegisterEventHotKey statuses, shown in Settings
    /// Explicit text entry is the only reason the panel may become key.
    @Published private(set) var noteFor: String? { didSet { updateTextEditing() } }

    @Published private(set) var questionInputFor: String? { didSet { updateTextEditing() } }

    let daemon: Daemon
    let settingsStore: SettingsStore
    let queue = CardQueue(clock: SystemClock())
    var hover = HoverIntent(clock: SystemClock())
    var hotkeys: HotkeyCenter?
    /// Set by PanelController; a hidden panel shows no card. Hiding forgets the card's visibility; showing re-reports it,
    /// so arming restarts from the show (never carried over from before the hide).
    var panelVisible = true {
        didSet {
            guard panelVisible != oldValue else { return }
            if !panelVisible {
                expanded = false; pinned = false
                hover = HoverIntent(clock: SystemClock()); hoverUntil = .distantPast
                lastCardReport = nil
                closeNote(); closeQuestionInput()
            }
            fullyVisibleRequestId = nil; cardScreenFrame = nil
            queue.sync(context: context()); queue.didRender(topId: nil)   // M1: a hidden panel must disarm now, not at the next tick
            if panelVisible, let r = lastCardReport { reportCardVisibility(id: r.id, frame: r.frame, viewport: r.viewport) }
        }
    }
    var showPanel: (() -> Void)?
    var hidePanel: (() -> Void)?
    var onPanelMoveEnd: (() -> Void)?
    /// Windows owned by MenubarController, reachable from the deck header even when macOS hides the menu-bar icon.
    var openSettingsWindow: (() -> Void)?
    var openAboutWindow: (() -> Void)?
    private var visibility = OverlayVisibility()
    private var pointerInside = false
    private(set) var pillPressed = false
    private var hoverSuppressedUntilExit = false
    var onNoteEditing: ((Bool) -> Void)?
    private var yourTurn = YourTurnTracker(clock: SystemClock())
    private var attention = AttentionTracker()
    @Published private(set) var completionCards: [YourTurnCard] = []
    @Published private(set) var pulsing = false
    @Published private(set) var glowing = false
    private lazy var notifications = NotificationCenterBridge { [weak self] id, action in
        guard let self, let request = self.sessions.flatMap(\.pending).first(where: { $0.id == id && $0.status == .pending }) else { return }
        if action == NotificationPlan.denyActionId {
            self.daemon.resolve(requestId: id, decision: .deny(note: nil), source: .notification) { [weak self] result in
                if case .applied = result {
                    self?.queue.noteApplied(requestId: id)
                    self?.requestPresentation.resolved(id)
                    if self?.noteFor == id { self?.closeNote() }
                    if self?.questionInputFor == id { self?.closeQuestionInput() }
                }
            }
        } else if action == NotificationPlan.showActionId {
            self.openInCursor(sessionId: request.sessionId)
        }
    }
    private var timer: Timer?
    private var lastSig = ""
    private var hoverUntil = Date.distantPast

    init(daemon: Daemon, settingsStore: SettingsStore, logURL: URL = AppPaths.live().logFile) {
        self.daemon = daemon; self.settingsStore = settingsStore
        navLog = MetaLog(url: logURL)
        settings = settingsStore.load()
        daemon.onChange = { [weak self] sessions in
            guard let self, self.sessions != sessions else { return }
            self.sessions = sessions; self.tick()
        }
    }

    func openSetupHelp() {
        guard let guide = Bundle.main.url(forResource: "AgentDeck-Guide", withExtension: "html"), NSWorkspace.shared.open(guide) else {
            setupStatus = "Setup guide could not be opened. Reinstall the complete AgentDeck app from your team package."
            return
        }
    }

    func installHooks() {
        guard !installingHooks else { return }
        installingHooks = true
        setupStatus = "Installing AgentDeck hooks…"
        daemon.repairHooks { [weak self] ok in
            guard let self else { return }
            self.installingHooks = false
            self.setupStatus = ok ? "Hooks installed. Restart your Claude Code tabs or terminal sessions, then start a harmless task to check the connection."
                : self.daemon.hookRepairError ?? "Hook installation failed. Check your Claude settings and use Setup & Help for recovery."
        }
    }

    deinit { timer?.invalidate() }

    var mutedIds: Set<String> { mutedIds(using: snapshot) }

    private func mutedIds(using snapshot: PresenceSnapshot?) -> Set<String> {
        guard let snap = snapshot else { return [] }
        var out = Set<String>()
        for s in sessions where PresenceRules.presence(host: s.host, snapshot: snap, settings: settings) == .present {
            for r in s.pending where r.channel == .race && r.status == .pending { out.insert(r.id) }
        }
        return out
    }

    private func context() -> QueueContext {
        QueueContext(expanded: expanded && panelVisible, quiet: settings.quiet, privacy: settings.privacy,
                     mutedIds: mutedIds, revealedId: revealedId,
                     cardFullyVisible: fullyVisibleRequestId != nil && fullyVisibleRequestId == queue.top?.id && queue.top.map { requestPresentation.reviewAtEnd.contains($0.id) } == true,
                     cardFrame: cardScreenFrame,
                     cwds: Dictionary(sessions.map { ($0.id, $0.workspaceRoot ?? $0.cwd) }, uniquingKeysWith: { a, _ in a }), collapsedIds: requestPresentation.collapsed,
                     noteEditingId: noteFor)
    }

    /// Panel top-left in screen points, set by PanelController: a panel move also moves the card under the pointer.
    var panelTopLeft: CGPoint = .zero {
        didSet { if panelTopLeft != oldValue, let r = lastCardReport { reportCardVisibility(id: r.id, frame: r.frame, viewport: r.viewport) } }
    }
    private var cardScreenFrame: CGRect?
    private var lastCardReport: (id: String?, frame: CGRect?, viewport: CGSize)?

    func reportCardVisibility(id: String?, frame: CGRect?, viewport: CGSize) {
        lastCardReport = (id, frame, viewport)
        let visible = frame.map { CardViewport.fullyVisible($0, in: CGRect(origin: .zero, size: viewport)) } ?? false
        let next = visible ? id : nil
        // Only equality matters, so the panel-relative frame (y down) is just shifted by the panel corner.
        let onScreen = visible ? frame?.offsetBy(dx: panelTopLeft.x, dy: -panelTopLeft.y) : nil
        guard next != fullyVisibleRequestId || onScreen != cardScreenFrame else { return }
        fullyVisibleRequestId = next; cardScreenFrame = onScreen
        queue.sync(context: context())
        queue.didRender(topId: next)
        objectWillChange.send()
        scheduleTick()
    }

    func pointer(inside: Bool) {
        pointerInside = inside
        if !inside { hoverSuppressedUntilExit = false }
        guard settings.hoverToOpen, !pillPressed, !hoverSuppressedUntilExit else { applyVisibility(); return }
        hover.pointer(inside: inside)
        hoverUntil = Date().addingTimeInterval(inside ? HoverIntent.expandDelay + 0.1 : HoverIntent.collapseDelay + 0.1)
        tick()
    }

    func pillInteraction(began: Bool, activate: Bool = false) {
        pillPressed = began
        hoverUntil = .distantPast
        hover = HoverIntent(clock: SystemClock())
        if !began {
            hoverSuppressedUntilExit = true
            if activate { expandPanel() } else { onPanelMoveEnd?() }
        }
        tick()
    }

    func expandPanel() {
        expanded = true; pinned = true; reveal(); tick()
        navLine("panel", "expand", "frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
    }

    func collapsePanel() {
        expanded = false; pinned = false
        hover = HoverIntent(clock: SystemClock()); hoverUntil = .distantPast
        hoverSuppressedUntilExit = true
        tick()
    }

    private func scheduleTick() {
        let now = Date()
        var dates = completionCards.map { $0.since.addingTimeInterval(YourTurnTracker.foldAfter) }
        if let next = queue.nextWakeAt { dates.append(next) }
        if settings.hoverToOpen, !pillPressed, !hoverSuppressedUntilExit, now < hoverUntil { dates.append(now.addingTimeInterval(0.1)) }
        if !settings.quiet {
            for r in queue.ordered where !mutedIds.contains(r.id) {
                dates += [AttentionLadder.pulseAt, AttentionLadder.notifyAt, AttentionLadder.cursorAt].map { r.createdAt.addingTimeInterval($0) }
            }
        }
        let next = dates.filter { $0 > now }.min()
        if let next, let timer, timer.isValid, abs(timer.fireDate.timeIntervalSince(next)) < 0.002 { return }
        timer?.invalidate(); timer = nil
        guard let next else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(0.001, next.timeIntervalSince(now) + 0.001), repeats: false) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.01
    }

    func tick() {
        let now = Date()
        let muted = mutedIds
        yourTurn.update(sessions)
        let cards = yourTurn.visible()
        if cards != completionCards { completionCards = cards }
        var retainedPresentation = requestPresentation
        retainedPresentation.retain(pending: Set(sessions.flatMap(\.pending).filter { $0.status == .pending }.map(\.id)))
        if retainedPresentation != requestPresentation { requestPresentation = retainedPresentation }
        let arrivals = queue.sync(pending: sessions.flatMap(\.pending), context: context())
        if !settings.quiet, !settings.privacy, arrivals.contains(where: { !muted.contains($0.id) }) {
            if settings.sounds { NSSound(named: "Pop")?.play() }
            if settings.hoverToOpen, !expanded, !pillPressed { expanded = true }
            reveal()
        }
        let requests = sessions.flatMap(\.pending)
        let eligible = requests.filter {
            $0.status == .pending && !muted.contains($0.id) && !settings.quiet &&
            AttentionLadder.stage(age: now.timeIntervalSince($0.createdAt)) != .waitingInCursor
        }
        notifications.synchronize(activeIds: Set(eligible.map(\.id)))
        for r in attention.dueForNotification(requests, mutedIds: muted, quiet: settings.quiet, now: now) {
            let index = sessions.firstIndex { $0.id == r.sessionId }
            notifications.post(r, session: index.map { sessions[$0] }, index: (index ?? 0) + 1, privacy: settings.privacy)
        }
        let pulse = !settings.quiet && attention.pulsing(requests, mutedIds: muted, now: now)
        if pulse != pulsing { pulsing = pulse }
        let glow = eligible.contains { AttentionLadder.stage(age: now.timeIntervalSince($0.createdAt)) == .expandGlow }
        if glow != glowing { glowing = glow }
        let target = hover.target(expanded: expanded, pinned: pinned, hasPending: !queue.ordered.isEmpty,
                                  enabled: settings.hoverToOpen && !pillPressed && !hoverSuppressedUntilExit)
        if target != expanded { expanded = target }
        if let r = revealedId, !queue.ordered.contains(where: { $0.id == r }) { revealedId = nil }
        queue.sync(context: context())
        if let n = noteFor, queue.showingTop?.id != n { closeNote() }
        if let id = questionInputFor, queue.showingTop?.id != id { closeQuestionInput() }
        // Queue state is not @Published: publish when what the views draw changes (top card, armed, status lines).
        let sig = "\(queue.ordered.map(\.id))|\(queue.showingTop?.id ?? "-")|\(queue.isArmed)|\(queue.visibleClosed().map(\.requestId))"
        if sig != lastSig { lastSig = sig; objectWillChange.send() }
        applyVisibility()
        scheduleTick()
    }

    /// Event-driven (called from tick only): show or hide the panel from the pure OverlayVisibility rule.
    private func applyVisibility() {
        let cards = !completionCards.isEmpty || !queue.visibleClosed().isEmpty
        let show = visibility.shouldShow(sessions: sessions, cardsVisible: cards, hovering: pointerInside, hideWhenIdle: settings.hideWhenIdle)
        guard show != panelVisible else { return }
        if show { showPanel?() } else { pointerInside = false; hidePanel?() }
    }

    /// Explicit user reveal (menubar Show, toggle hotkey, expand-only): visible until the next active -> idle transition.
    private func reveal() {
        visibility.reveal()
        if !panelVisible { showPanel?() }
    }

    func toggleVisible() {
        if panelVisible { visibility.userHide() } else { visibility.reveal() }
        tick()
    }

    func perform(_ action: CardAction, renderedId: String?, via: ActionTrigger) {
        queue.sync(context: context())   // M1: decide on the current panel/visibility state, never one from the last tick
        switch queue.perform(action, renderedId: renderedId, via: via) {
        case .send(let id, let decision, let source):
            daemon.resolve(requestId: id, decision: decision, source: source) { [weak self] result in
                if case .applied = result {
                    self?.queue.noteApplied(requestId: id)
                    self?.requestPresentation.resolved(id)
                    if self?.noteFor == id { self?.closeNote() }
                    if self?.questionInputFor == id { self?.closeQuestionInput() }
                }
            }
        case .expandOnly(let id):
            expanded = true; revealedId = id
            reveal()
            tick()
        case .dropped(let why):
            navLog.write("\(ISO8601DateFormatter().string(from: Date())) card action dropped reason=\(why.rawValue)")   // metadata only
            if let id = renderedId { showCardNotice(id, HoldReason.dropText(why)) }
        }
    }

    func holdReleasedEarly(_ id: String) {
        navLog.write("\(ISO8601DateFormatter().string(from: Date())) card action dropped reason=holdReleasedEarly id=\(id.prefix(8))")
    }

    private func showCardNotice(_ id: String, _ text: String) {
        cardNoticeWork?.cancel()
        cardNotice = (id, text)
        let w = DispatchWorkItem { [weak self] in self?.cardNotice = nil }
        cardNoticeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    func collapseRequest(_ id: String) {
        requestPresentation.collapse(id, noteEditorOpen: noteFor == id)
        fullyVisibleRequestId = nil; cardScreenFrame = nil
        closeNote(); closeQuestionInput(); tick()
    }

    func expandRequest(_ id: String) {
        let reopenNote = requestPresentation.expand(id)
        revealedId = id
        fullyVisibleRequestId = nil; cardScreenFrame = nil
        tick()
        if reopenNote, queue.showingTop?.id == id { openNote(for: id) }
    }

    /// The note field keeps its text locally while typing (no deck republish per keystroke) and saves it here when it goes away.
    /// A request that is no longer pending keeps no draft.
    func saveNote(_ text: String, for id: String) {
        guard sessions.contains(where: { $0.pending.contains { $0.id == id && $0.status == .pending } }) else { return }
        let value: String? = text.isEmpty ? nil : text
        if requestPresentation.notes[id] != value { requestPresentation.notes[id] = value }
    }

    func reportReviewEnd(_ id: String, visible: Bool) {
        let visible = visible && !requestPresentation.collapsed.contains(id) && queue.top?.id == id
        let was = requestPresentation.reviewAtEnd.contains(id)
        guard was != visible else { return }
        if visible { requestPresentation.reviewAtEnd.insert(id) } else { requestPresentation.reviewAtEnd.remove(id) }
        queue.sync(context: context())
        queue.didRender(topId: fullyVisibleRequestId)
        objectWillChange.send()
        scheduleTick()
    }

    var cardHeight: CGFloat { max(160, min(500, maxPanelHeight - 100)) }

    func dismissCompletion(sessionId: String) {
        yourTurn.dismiss(sessionId: sessionId)
        completionCards = yourTurn.visible()
    }

    func dismiss(requestId: String) {
        queue.noteApplied(requestId: requestId)   // our own action: no "Handled elsewhere" line
        daemon.dismiss(requestId: requestId)
    }

    /// Which session a decision card belongs to (same-name sessions differ by #id). Cards never render in privacy mode.
    func cardSessionLabel(_ sessionId: String) -> String {
        guard let s = sessions.first(where: { $0.id == sessionId }) else { return "#" + String(sessionId.prefix(6)) }
        return "\(RowFormat.title(s)) · \(RowFormat.shortId(s))"
    }

    // shortcut: a second MetaLog on the daemon's log file (Daemon has no public log helper); appends race only with simultaneous daemon writes.
    private let navLog: MetaLog
    private func navLine(_ tag: String, _ step: String, _ result: String) {
        navLog.write("\(ISO8601DateFormatter().string(from: Date())) open \(tag) step=\(step) result=\(result)")
    }

    /// Executes SessionNavigator.plan in order. Navigation only: never resolves a request. Logs metadata (short id, step kind) only.
    func openInCursor(sessionId: String) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { navLine("-", "lookup", "notFound"); return }
        // A live session's folder exists; stat'ing it (e.g. ~/Documents) would raise a macOS privacy prompt.
        let steps = SessionNavigator.plan(for: session, cursorBundleIds: settings.cursorBundleIds,
                                          deepLinkTemplate: daemon.matrix.deepLinkTemplate,
                                          isDirectory: { _ in session.state != .ended },
                                          workspaceFor: { WorkspaceResolver.target(forRoot: $0, candidates: Self.workspaceCandidates()) })
        navLine(RowFormat.shortId(session), "plan", "\(steps.count)")
        run(steps[...], tag: RowFormat.shortId(session))
    }

    /// Read-only, on demand: Cursor's workspaceStorage entries that point at a .code-workspace, plus that file's folders.
    private static func workspaceCandidates() -> [WorkspaceCandidate] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var best: [String: WorkspaceCandidate] = [:]
        for d in dirs {
            guard let data = try? Data(contentsOf: d.appendingPathComponent("workspace.json")),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ws = obj["workspace"] as? String, let url = URL(string: ws), url.isFileURL, url.pathExtension == "code-workspace",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let folders = WorkspaceResolver.folders(inWorkspaceFile: text, baseDir: url.deletingLastPathComponent().path)
            else { continue }
            let used = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if let old = best[url.path], old.lastUsed >= used { continue }
            best[url.path] = WorkspaceCandidate(workspaceFilePath: url.path, folders: folders, lastUsed: used)
        }
        return Array(best.values)
    }

    private func run(_ steps: ArraySlice<NavigationStep>, tag: String) {
        guard let step = steps.first else { return }
        let rest = steps.dropFirst()
        switch step {
        case .focusFolder(let path, let bundleId), .openWorkspace(let path, let bundleId):
            let name: String
            if case .openWorkspace = step { name = "openWorkspace" } else { name = "focusFolder" }
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                navLine(tag, name, "appNotFound"); run(rest, tag: tag); return
            }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            // The deep link must land in the window that owns the folder, so continue only once the host has opened it.
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: config) { [weak self] _, error in
                DispatchQueue.main.async {
                    self?.navLine(tag, name, (error as NSError?).map { String($0.code) } ?? "ok")
                    self?.run(rest, tag: tag)
                }
            }
        case .activateApp(let bundleId):
            let ok = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate() ?? false
            navLine(tag, "activateApp", ok ? "ok" : "notRunning")
            run(rest, tag: tag)
        case .openURL(let url):
            navLine(tag, "openURL", NSWorkspace.shared.open(url) ? "ok" : "failed")
            run(rest, tag: tag)
        }
    }

    private func updateTextEditing() { onNoteEditing?(noteFor != nil || questionInputFor != nil) }
    func openQuestionInput(for id: String) { questionInputFor = id }
    func closeQuestionInput() { questionInputFor = nil }
    func openNote(for id: String) { noteFor = id }
    func closeNote() { noteFor = nil }

    func handle(_ action: HotkeyAction) {
        switch action {
        case .toggleExpand:
            reveal()
            if expanded { collapsePanel() } else { expandPanel() }
        case .allowTop: perform(.allow, renderedId: queue.renderedId, via: .hotkey)
        case .denyTop: perform(.deny(note: nil), renderedId: queue.renderedId, via: .hotkey)
        case .openTop: if let id = queue.top?.sessionId { openInCursor(sessionId: id) }
        case .privacy: update { $0.privacy.toggle() }
        }
    }

    func update(_ change: (inout AppSettings) -> Void) {
        let privacyBefore = settings.privacy
        let hoverBefore = settings.hoverToOpen
        change(&settings)
        if hoverBefore != settings.hoverToOpen {
            hover = HoverIntent(clock: SystemClock()); hoverUntil = .distantPast
            hoverSuppressedUntilExit = pointerInside
        }
        if privacyBefore != settings.privacy {
            attention = AttentionTracker()
            notifications.synchronize(activeIds: [], reset: true)
            closeNote(); closeQuestionInput()
        }
        settingsStore.save(settings)
        daemon.update(settings: settings)
        tick()
    }

    func applyHotkeys() {
        hotkeyConfig = HotkeyStore().load()
        hotkeyFailures = (hotkeys?.apply(hotkeyConfig) ?? [:]).filter { $0.value != 0 }
    }

    /// nil = ok, else the inline error for the settings window.
    func rebind(_ action: HotkeyAction, to key: Hotkey) -> String? {
        do {
            let c = try hotkeyConfig.setting(action, to: key)
            HotkeyStore().save(c); applyHotkeys()
            return hotkeyFailures[action].map { "Could not register \(HotkeyLabel.text(key)) (status \($0)); another app may own it" }
        } catch HotkeyError.missingControl { return "The shortcut must include Control (⌃)"
        } catch HotkeyError.duplicate(let other) { return "Already used by \(other.rawValue)"
        } catch { return "\(error)" }
    }
}
