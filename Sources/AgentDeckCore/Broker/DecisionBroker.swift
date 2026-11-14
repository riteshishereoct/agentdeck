import Foundation

public protocol HoldWaiter: AnyObject { func finish(_ body: Data?) }

/// Not thread-safe: call on the core queue.
public final class DecisionBroker {
    private struct Entry {
        var request: Request
        var waiter: HoldWaiter?
        let host: String?
        var presentSince: Date?
        /// The hook shell's own pid from `X-Adeck-Hook-Pid` on the wait; nil for an older hook (no liveness check).
        var hookPid: Int32?
    }

    static let holdWindow: TimeInterval = 2
    static let releaseAfter: TimeInterval = 590
    static let presenceRelease: TimeInterval = 3
    /// Date arithmetic on ~1.8e9 s loses ~1e-7; limits are inclusive within a millisecond.
    private static let slack: TimeInterval = 0.001
    /// Amendment A4: any other permission_mode is unverified and never allows a hold.
    private static let knownModes: Set<String> = ["default", "acceptEdits", "auto", "plan", "bypassPermissions", "dontAsk"]

    private let clock: Clock
    private var matrix: CapabilityMatrix
    private var settings: AppSettings
    private let rules: (String) -> SettingsRules
    private let emit: (AgentEvent) -> Void
    private var presence: PresenceSnapshot?
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private struct Recent { let sessionId: String; let agentId: String?; let tool: String?; let input: JSONValue?; let toolUseId: String?; let at: Date }
    private struct Backstop { let input: HookInput; let host: String?; let deadline: Date }
    private var recent: [Recent] = []
    private var backstops: [Backstop] = []
    static let correlationWindow: TimeInterval = 30
    static let backstopAfter: TimeInterval = 6
    /// A channel-3 notice nobody resolved or dismissed: after this it expires, so a stuck session can go quiet (review H3).
    static let noticeExpiry: TimeInterval = 600
    private static let noBackstop: Set<String> = ["Bash", "Task", "Agent", "WebFetch", "WebSearch"]
    /// Test seam: is the hook shell holding a wait still running?
    var hookAlive: (Int32) -> Bool = DecisionBroker.processAlive
    /// Called with the request id after a held request is released because its hook shell died.
    var onHookDied: ((String) -> Void)?

    public init(clock: Clock, matrix: CapabilityMatrix, settings: AppSettings,
                rules: @escaping (_ cwd: String) -> SettingsRules, emit: @escaping (AgentEvent) -> Void) {
        self.clock = clock; self.matrix = matrix; self.settings = settings; self.rules = rules; self.emit = emit
    }

    public func update(settings: AppSettings) { self.settings = settings }
    public func update(matrix: CapabilityMatrix) { self.matrix = matrix }
    public func update(presence: PresenceSnapshot) { self.presence = presence }

    var hasTimedWork: Bool { !backstops.isEmpty || entries.values.contains { $0.request.channel != .notify } }

    public var pending: [Request] { order.compactMap { entries[$0]?.request } }

    // MARK: scoping and helpers

    private func scoped(host: String?, entrypoint: String?) -> Bool {
        if settings.paused { return false }
        if entrypoint?.hasPrefix("sdk") == true { return false }
        if let host, settings.cursorBundleIds.contains(host) { return true }
        return settings.gateOtherHosts && host != nil
    }

    private func verified(_ mode: String?) -> Bool { mode.map(Self.knownModes.contains) ?? false }

    private func reached(_ since: Date, _ limit: TimeInterval, _ now: Date) -> Bool {
        now.timeIntervalSince(since) >= limit - Self.slack
    }

    private static func kind(forTool tool: String) -> RequestKind {
        switch tool {
        case "ExitPlanMode": return .planReview
        case "AskUserQuestion": return .question
        default: return .permission
        }
    }

    private static func answerable(_ v: JSONValue?) -> Bool {
        !QuestionForm.parse(v ?? .null).isEmpty
    }

    private func makeRequest(_ input: HookInput, hook: HookKind, kind: RequestKind, channel: Channel, toolUseId: String?,
                             preview: String? = nil) -> Request {
        let tool = input.toolName ?? ""
        let body = input.toolInput ?? .null
        return Request(id: UUID().uuidString, sessionId: input.sessionId, agentId: input.agentId, kind: kind, hook: hook, tool: tool,
                       toolUseId: toolUseId, preview: Ingest.preview(preview ?? StepLabel.label(tool: tool, input: body)), fullInput: body,
                       risk: RiskRules.classify(tool: tool, input: body, cwd: input.cwd ?? ""),
                       suggestions: input.permissionSuggestions, personOnly: input.personOnly, channel: channel,
                       createdAt: clock.now(), status: .pending)
    }

    private func store(_ r: Request, host: String?) {
        entries[r.id] = Entry(request: r, waiter: nil, host: host)
        order.append(r.id)
    }

    private func event(_ kind: EventKind, for r: Request) -> AgentEvent {
        AgentEvent(sessionId: r.sessionId, agentId: r.agentId, kind: kind, ts: clock.now())
    }

    /// A channel-3 notice: no hook is held, so it reaches the store at once.
    @discardableResult
    private func addNotice(_ input: HookInput, hook: HookKind, kind: RequestKind, host: String?, toolUseId: String?,
                           preview: String? = nil) -> Bool {
        if let t = toolUseId, entries.values.contains(where: { $0.request.toolUseId == t && $0.request.sessionId == input.sessionId }) { return false }
        if kind == .planReview, entries.values.contains(where: { $0.request.kind == .planReview && $0.request.sessionId == input.sessionId }) { return false }
        let r = makeRequest(input, hook: hook, kind: kind, channel: .notify, toolUseId: toolUseId, preview: preview)
        store(r, host: host)
        emit(event(.requestHeld(r), for: r))
        return true
    }

    /// A held request exists in `entries` but is announced to the store only once a waiter attaches (amendment A2).
    private func makeHold(_ input: HookInput, hook: HookKind, kind: RequestKind, channel: Channel, toolUseId: String?, host: String?) -> GateVerb {
        let r = makeRequest(input, hook: hook, kind: kind, channel: channel, toolUseId: toolUseId)
        store(r, host: host)
        return .hold(id: r.id)
    }

    /// The single exit: removes the entry, tells the waiter (a body, or an empty release), emits the status.
    private func finish(_ id: String, _ status: RequestStatus, release: Bool = false, body: Data? = nil) {
        guard let e = entries.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        if body != nil || release { e.waiter?.finish(body) }
        emit(event(.requestUpdated(id: id, status: status), for: e.request))
    }

    // MARK: endpoints

    public func decide(_ input: HookInput, meta: HookMeta) -> GateVerb {
        guard scoped(host: meta.host, entrypoint: meta.entrypoint) else { return .pass }
        let tool = input.toolName ?? ""
        let tid = correlatedToolUseId(input)
        let kind = Self.kind(forTool: tool)
        if kind == .permission, matrix.channel(forTool: tool) == .race, verified(input.permissionMode) {   // never a question or plan
            return makeHold(input, hook: .permissionRequest, kind: kind, channel: .race, toolUseId: tid, host: meta.host)
        }
        // A PermissionRequest firing proves a native prompt is showing.
        addNotice(input, hook: .permissionRequest, kind: kind, host: meta.host, toolUseId: tid)
        return .pass
    }

    private static let readOnly: Set<String> = ["Read", "Grep", "Glob", "LS", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"]
    /// Claude Code prompts for these outside the working directory in default mode (review M5).
    private static let pathReads: [String: String] = ["Read": "file_path", "Grep": "path", "Glob": "path", "LS": "path"]
    private static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private static let freeModes: Set<String> = ["bypassPermissions", "plan", "dontAsk"]

    /// G-FALSE-BACKSTOP: no "needs approval" guess where Claude Code shows no prompt; a slow auto-mode classifier is not a prompt.
    static func mayPrompt(tool: String, mode: String?, input: JSONValue? = nil, cwd: String? = nil) -> Bool {
        if let m = mode, freeModes.contains(m) || m == "auto" { return false }
        if mode == "acceptEdits", editTools.contains(tool) { return false }
        if let key = pathReads[tool] { return !inside(input?[key]?.stringValue, cwd: cwd) }
        return !readOnly.contains(tool)
    }

    /// No path = the working directory. Unknown cwd with an absolute path: may prompt. shortcut: `..` and symlinks are not
    /// resolved and additional directories are unknown, so such reads may get a (harmless) backstop notice.
    private static func inside(_ path: String?, cwd: String?) -> Bool {
        guard let path, !path.isEmpty else { return true }
        guard let cwd, !cwd.isEmpty else { return !path.hasPrefix("/") && !path.hasPrefix("~") }
        if path.hasPrefix("~") { return false }
        let full = path.hasPrefix("/") ? path : cwd + "/" + path
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return (full == base || full.hasPrefix(base + "/")) && !full.contains("/../")
    }

    private func presenceOf(host: String?) -> Presence {
        let snap = presence ?? PresenceSnapshot(frontmostBundleId: nil, idleSeconds: 0, at: clock.now())
        return PresenceRules.presence(host: host, snapshot: snap, settings: settings)
    }

    /// Why the last gate() call answered PASS (metadata for the log; set only on diagnosed paths, cleared on entry).
    public private(set) var lastPassReason: String?

    public func gate(_ input: HookInput, meta: HookMeta) -> GateVerb {
        lastPassReason = nil
        guard scoped(host: meta.host, entrypoint: meta.entrypoint) else { return .pass }
        let tool = input.toolName ?? ""
        let mode = input.permissionMode
        recent.append(Recent(sessionId: input.sessionId, agentId: input.agentId, tool: input.toolName, input: input.toolInput,
                             toolUseId: input.toolUseId, at: clock.now()))
        if input.toolUseId != nil, !Self.noBackstop.contains(tool), !tool.hasPrefix("mcp__"), Self.mayPrompt(tool: tool, mode: mode, input: input.toolInput, cwd: input.cwd) {
            backstops.append(Backstop(input: input, host: meta.host, deadline: clock.now().addingTimeInterval(Self.backstopAfter)))
        }
        if tool == "ExitPlanMode" {
            addNotice(input, hook: .preToolUse, kind: .planReview, host: meta.host, toolUseId: input.toolUseId)
            return .pass
        }
        if tool == "AskUserQuestion" {   // spec §7: no permission mode or rule bypasses a question while you are away
            if presenceOf(host: meta.host) == .present { lastPassReason = "present"; return .pass }
            if matrix.channel(forTool: tool) == .gate, verified(mode), Self.answerable(input.toolInput) {
                return makeHold(input, hook: .preToolUse, kind: .question, channel: .gate, toolUseId: input.toolUseId, host: meta.host)
            }
            lastPassReason = matrix.channel(forTool: tool) != .gate ? "channel" : !verified(mode) ? "unverifiedMode(\(mode ?? "nil"))" : "notAnswerable"
            addNotice(input, hook: .preToolUse, kind: .question, host: meta.host, toolUseId: input.toolUseId)
            return .pass
        }
        guard matrix.channel(forTool: tool) == .gate else { return .pass }
        if presenceOf(host: meta.host) == .present { return .pass }
        if let m = mode, Self.freeModes.contains(m) { return .pass }
        if mode == "acceptEdits", Self.editTools.contains(tool) { return .pass }
        if Self.readOnly.contains(tool) { return .pass }
        let body = input.toolInput ?? .null
        let r = rules(input.cwd ?? "")
        if r.mayDeny(tool: tool, input: body) || r.simplyAllows(tool: tool, input: body) { return .pass }
        let scope = settings.gateScope == .automatic ? (mode == "auto" ? GateScope.riskyOnly : .full) : settings.gateScope
        if scope == .riskyOnly, RiskRules.classify(tool: tool, input: body, cwd: input.cwd ?? "").level == .low { return .pass }
        if !verified(mode) {                           // amendment A4: unknown mode never holds
            addNotice(input, hook: .preToolUse, kind: Self.kind(forTool: tool), host: meta.host, toolUseId: input.toolUseId)
            return .pass
        }
        return makeHold(input, hook: .preToolUse, kind: .permission, channel: .gate, toolUseId: input.toolUseId, host: meta.host)
    }

    /// Protocol §6 "Handled elsewhere": only these events resolve a request; an unrelated newer event never does.
    public func observe(_ event: AgentEvent) {
        func release(_ match: (Request) -> Bool) {
            for id in order where entries[id].map({ $0.request.sessionId == event.sessionId && match($0.request) }) == true {
                finish(id, .handledElsewhere, release: true)
            }
        }
        switch event.kind {
        case .hook(.postToolUse), .hook(.postToolUseFailure), .hook(.permissionDenied), .transcriptToolResult:
            guard let t = event.toolUseId else { return }
            backstops.removeAll { $0.input.toolUseId == t && $0.input.sessionId == event.sessionId }
            release { $0.toolUseId == t }
        case .hook(.userPromptSubmit), .hook(.stop), .hook(.sessionEnd), .pidGone:
            backstops.removeAll { $0.input.sessionId == event.sessionId }
            release { _ in true }
        case .hook(.subagentStop):
            guard let a = event.agentId else { return }
            release { $0.agentId == a }
        case .hook(.notification) where event.notificationType == "permission_prompt":
            guard scoped(host: event.host, entrypoint: event.entrypoint),
                  !entries.values.contains(where: { $0.request.sessionId == event.sessionId }) else { return }
            let input = HookInput(sessionId: event.sessionId, cwd: event.cwd)
            addNotice(input, hook: .notification, kind: .permission, host: event.host, toolUseId: nil,
                      preview: Masking.mask(event.text ?? "Needs approval"))
        default: break
        }
    }

    private func correlatedToolUseId(_ input: HookInput) -> String? {
        let now = clock.now()
        return recent.last {
            $0.toolUseId != nil && $0.sessionId == input.sessionId && $0.agentId == input.agentId && $0.tool == input.toolName
                && $0.input == input.toolInput && now.timeIntervalSince($0.at) <= Self.correlationWindow
        }?.toolUseId
    }

    /// A SIGKILLed hook cannot run its trap, so its orphan curl keeps the wait open: liveness of the shell is the truth.
    /// A zombie counts as dead; a failed lookup counts as alive (unknown is never dead).
    static func processAlive(_ pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return true }
        return size > 0 && Int32(info.kp_proc.p_stat) != SZOMB
    }

    private func hookDied(_ e: Entry) -> Bool { e.hookPid.map { !hookAlive($0) } ?? false }

    private func releaseDeadHook(_ id: String) {
        finish(id, .handledElsewhere, release: true)   // closing the wait also ends the orphan curl
        onHookDied?(id)
    }

    public func attach(id: String, waiter: HoldWaiter, hookPid: Int32? = nil) -> Bool {
        guard var e = entries[id], e.request.channel != .notify, e.waiter == nil, e.request.status == .pending else { return false }
        if reached(e.request.createdAt, Self.holdWindow, clock.now()) {
            finish(id, .hookGone)
            return false
        }
        e.waiter = waiter
        e.hookPid = hookPid
        entries[id] = e
        emit(event(.requestHeld(e.request), for: e.request))
        return true
    }

    public func waiterClosed(id: String) {
        guard entries[id]?.waiter != nil else { return }
        finish(id, .handledElsewhere)
    }

    public func resolve(id: String, decision: Decision, source: DecisionSource) -> ResolveResult {
        guard let e = entries[id], e.request.status == .pending else { return .dropped(.unknownOrResolved) }
        let r = e.request
        if r.channel == .notify { return .dropped(.notApplicable) }
        guard e.waiter != nil else { return .dropped(.unknownOrResolved) }
        if hookDied(e) { releaseDeadHook(id); return .dropped(.unknownOrResolved) }   // nothing would reach Claude
        var allows = true, plainAllow = false, status = RequestStatus.allowed
        switch decision {
        case .allow, .allowAlways:
            if r.kind != .permission { return .dropped(.notApplicable) }   // a question is answered or denied, never allowed blank
            plainAllow = true
        case .answer: status = .answered
        case .deny: allows = false; status = .denied
        }
        if allows && r.personOnly { return .dropped(.personOnly) }
        if allows && source == .notification { return .dropped(.notAllowedFromSource) }
        if plainAllow && r.risk.level == .high && source != .holdConfirmed { return .dropped(.needsHoldConfirm) }
        // Spec §8: only on a race PermissionRequest; Envelopes accepts only an entry the request offered, verbatim.
        if case .allowAlways = decision, r.channel != .race || r.hook != .permissionRequest { return .dropped(.notApplicable) }
        guard let body = try? Envelopes.data(for: r, decision: decision) else { return .dropped(.notApplicable) }
        finish(id, status, body: body)
        return .applied
    }

    public func dismiss(id: String) {
        guard let e = entries[id], e.request.channel == .notify else { return }
        finish(id, .handledElsewhere)
    }

    public func tick(now: Date) {
        recent.removeAll { now.timeIntervalSince($0.at) > Self.correlationWindow }
        let due = backstops.filter { reached($0.deadline, 0, now) }
        backstops.removeAll { b in due.contains { $0.input.toolUseId == b.input.toolUseId && $0.input.sessionId == b.input.sessionId } }
        for b in due {
            addNotice(b.input, hook: .preToolUse, kind: Self.kind(forTool: b.input.toolName ?? ""), host: b.host, toolUseId: b.input.toolUseId)
        }
        for id in order {
            guard let e = entries[id] else { continue }
            if e.request.channel == .notify {
                if reached(e.request.createdAt, Self.noticeExpiry, now) { finish(id, .timedOut) }
                continue
            }
            if e.waiter == nil {
                if reached(e.request.createdAt, Self.holdWindow, now) { finish(id, .hookGone) }
            } else if hookDied(e) {
                releaseDeadHook(id)
            } else if reached(e.request.createdAt, Self.releaseAfter, now) {
                finish(id, .timedOut, release: true)
            } else if e.request.channel == .gate {
                if presenceOf(host: e.host) == .present {
                    let since = e.presentSince ?? now
                    entries[id]?.presentSince = since
                    if reached(since, Self.presenceRelease, now) { finish(id, .movedToCursor, release: true) }
                } else {
                    entries[id]?.presentSince = nil
                }
            }
        }
    }
}
