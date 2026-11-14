import Foundation

public struct AppPaths: Equatable, Sendable {
    public var supportDir: URL
    public var socket: URL
    public var capabilities: URL
    public var snapshot: URL
    public var logFile: URL
    public var home: URL

    public init(supportDir: URL, socket: URL, capabilities: URL, snapshot: URL, logFile: URL, home: URL) {
        self.supportDir = supportDir; self.socket = socket; self.capabilities = capabilities
        self.snapshot = snapshot; self.logFile = logFile; self.home = home
    }

    public static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppPaths {
        let support = home.appendingPathComponent("Library/Application Support/AgentDeck", isDirectory: true)
        return AppPaths(supportDir: support,
                        socket: support.appendingPathComponent("adeck.sock"),
                        capabilities: support.appendingPathComponent("capabilities.json"),
                        snapshot: support.appendingPathComponent("sessions.json"),
                        logFile: home.appendingPathComponent("Library/Logs/AgentDeck/agentdeck.log"),
                        home: home)
    }
}

public final class Daemon {
    /// All core state (store, broker, sockets, timers) lives on this one serial queue.
    let queue = DispatchQueue(label: "agentdeck.core")
    /// Test seam: called on `queue` for every event the broker emits.
    var emitObserver: ((AgentEvent) -> Void)?
    /// Test seam for amendment A1's pid walk (nil = unknown). Set before `start()`.
    var resolvePid: (Int32) -> Int32? = { Liveness.resolveClaudePid($0) }
    /// Test seam: set before `start()`; nil uses the live nested `claude -p` runner.
    var summarizerRunner: SummarizerRunner?
    /// Folder holding the bundled `hooks/adeck-hook` and `installer/install.sh` (the repo or the app's Resources). Set before
    /// `start()`. nil: the installed hook is only checked for presence, and Repair hooks is unavailable.
    public var hookSource: URL?

    private let paths: AppPaths
    private let clock: Clock
    private let store: SessionStore
    private let log: MetaLog
    private var broker: DecisionBroker!
    private var settings: AppSettings
    private var tailer: TranscriptTailer!
    private var summarizer: Summarizer?
    private var server: SocketServer!
    /// Listeners replaced by a health-check restart; kept so their open waits (live requests) finish normally.
    private var retiredServers: [SocketServer] = []
    private var healthTimers: [String: (at: Date, item: DispatchWorkItem)] = [:]
    /// Test seam for a missing system interpreter; normal operation always uses /usr/bin/python3.
    var repairPythonExecutable = URL(fileURLWithPath: "/usr/bin/python3")
    public private(set) var hookRepairError: String?
    private var repairing = false
    private var _matrix = CapabilityMatrix.fallback
    private var _onChange: (([Session]) -> Void)?
    private var running = false
    private var changeScheduled = false
    private var tickTimer: DispatchSourceTimer?
    private var livenessTimer: DispatchSourceTimer?
    private var tickInterval: TimeInterval?

    private static let eventHooks: Set<HookKind> = [.sessionStart, .sessionEnd, .userPromptSubmit, .postToolUse, .postToolUseFailure,
                                                    .notification, .stop, .subagentStart, .subagentStop, .preCompact, .permissionDenied]

    public init(paths: AppPaths, settings: AppSettings, clock: Clock = SystemClock()) {
        self.paths = paths; self.clock = clock; self.settings = settings
        store = SessionStore(launchedAt: clock.now())   // the injected clock, like every event timestamp
        log = MetaLog(url: paths.logFile)
        broker = DecisionBroker(clock: clock, matrix: _matrix, settings: settings,
                                rules: { [home = paths.home] in SettingsRules.load(home: home, cwd: $0) },
                                emit: { [unowned self] in brokerEmitted($0) })
        broker.onHookDied = { [unowned self] in log.write(Daemon.hookDiedAudit(stamp: stamp(), requestId: $0)) }
        server = SocketServer(path: paths.socket.path, queue: queue, handler: { [unowned self] in route($0, $1) })
        tailer = TranscriptTailer(emit: { [unowned self] in ingest($0) })   // transcript events reach the store and the broker
    }

    /// Delivered on the main queue, coalesced to at most one call per 50 ms.
    public var onChange: (([Session]) -> Void)? {
        get { queue.sync { _onChange } }
        set { queue.sync { _onChange = newValue } }
    }

    /// For the UI's deep links. Never call from the core queue.
    public var matrix: CapabilityMatrix { queue.sync { _matrix } }

    public func start() throws {
        try FileManager.default.createDirectory(at: paths.supportDir, withIntermediateDirectories: true)
        chmod(paths.supportDir.path, 0o700)
        let m = CapabilityMatrix.load(from: paths.capabilities)
        try server.start()   // throws before any other side effect that needs undoing
        queue.sync {
            _matrix = m
            broker.update(matrix: m)
            running = true
            let s = Summarizer(runner: summarizerRunner ?? LiveSummarizerRunner(callbackQueue: queue), clock: clock)
            s.enabled = settings.summarizer   // plan-validation B3: off by default, follows settings
            summarizer = s
            store.restore(SnapshotIO.load(from: paths.snapshot))   // no SessionStart replay: model and startedAt survive; goal is re-read from the transcript
            changed()
        }
    }

    private func refreshTimers() {
        guard running else { return }
        let active = store.sessions.values.contains { [.working, .error, .needsYou, .waitingInCursor].contains($0.state) }
        // 10 Hz only while the broker has timed work (holds, backstops); otherwise 1 Hz while anything is active or ending, else none.
        let interval: TimeInterval? = broker.hasTimedWork ? 0.1 : (active || store.sessions.values.contains { $0.state == .ended } ? 1 : nil)
        if interval != tickInterval {
            tickTimer?.cancel(); tickTimer = nil; tickInterval = interval
            if let interval { tickTimer = repeating(interval) { [self] in tickNow() } }
        }
        if active, livenessTimer == nil { livenessTimer = repeating(Liveness.checkInterval) { [self] in checkLiveness() } }
        if !active { livenessTimer?.cancel(); livenessTimer = nil }
    }

    private func repeating(_ interval: TimeInterval, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 100)))   // 10 % leeway
        t.setEventHandler(handler: body)
        t.resume()
        return t
    }

    /// 100 ms timer body (also called directly by tests with a fake clock).
    func tickNow() {
        let now = clock.now()
        let activeTranscripts = Set(store.sessions.values.filter { [.working, .error].contains($0.state) }.map(\.id))
        tailer.poll(now: now, activeSessionIds: activeTranscripts)
        broker.tick(now: now)
        let before = store.sessions
        store.apply(AgentEvent(sessionId: "", kind: .tick, ts: now))   // store-wide: never creates a session
        if store.sessions != before { changed() }
        refreshTimers()
    }

    /// Amendment A1: only sessions with a verified (non-nil) pid can end by `.pidGone`.
    func checkLiveness() {
        let now = clock.now()
        for s in store.sessions.values where s.state != .ended {
            if let pid = s.pid, !Liveness.isAlive(pid) { ingest(AgentEvent(sessionId: s.id, kind: .pidGone, ts: now)) }
        }
    }

    public func stop() {
        queue.sync {
            running = false
            tickTimer?.cancel(); tickTimer = nil; tickInterval = nil
            livenessTimer?.cancel(); livenessTimer = nil
        }
        queue.sync { for t in healthTimers.values { t.item.cancel() }; healthTimers = [:] }
        for s in retiredServers { s.stop() }
        server.stop()   // open waits see EOF, so their hooks fail open
    }

    public func update(settings: AppSettings) {
        queue.async { [self] in
            self.settings = settings
            summarizer?.enabled = settings.summarizer
            broker.update(settings: settings)
        }
    }
    public func update(presence: PresenceSnapshot) { queue.async { [self] in broker.update(presence: presence) } }

    public func reloadMatrix() {
        let m = CapabilityMatrix.load(from: paths.capabilities)
        queue.async { [self] in _matrix = m; broker.update(matrix: m) }
    }

    public func resolve(requestId: String, decision: Decision, source: DecisionSource,
                        completion: @escaping (ResolveResult) -> Void) {
        queue.async { [self] in
            let r = broker.resolve(id: requestId, decision: decision, source: source)
            log.write(Daemon.decisionAudit(stamp: stamp(), requestId: requestId, decision: decision, source: source, result: r))
            DispatchQueue.main.async { completion(r) }
        }
    }

    /// Metadata-only audit of a person's decision attempt: kind, source and outcome; never note text or answers.
    static func decisionAudit(stamp: String, requestId: String, decision: Decision, source: DecisionSource, result: ResolveResult) -> String {
        let kind: String
        switch decision {
        case .allow: kind = "allow"
        case .allowAlways: kind = "allowAlways"
        case .deny(let note): kind = note?.isEmpty == false ? "deny+note" : "deny"
        case .answer(let a): kind = "answer(\(a.count))"
        }
        let outcome: String
        switch result { case .applied: outcome = "applied"; case .dropped(let why): outcome = "dropped:\(why.rawValue)" }
        return "\(stamp) decision \(requestId) kind=\(kind) source=\(source.rawValue) result=\(outcome)"
    }

    /// Metadata-only line for a hold released because the hook shell holding it died (SIGKILL): the card can no longer reach Claude.
    static func hookDiedAudit(stamp: String, requestId: String) -> String {
        "\(stamp) release \(requestId) kind=hookDied result=handledElsewhere"
    }

    public func dismiss(requestId: String) { queue.async { [self] in broker.dismiss(id: requestId) } }

    // MARK: hook health (docs/hook-health.md): read-only checks, AgentDeck-internal fixes only, bounded one-shot timers

    /// "Check connection" / "Retry" on a row: a new bounded check episode for that session. Never touches requests or navigation.
    public func checkHookHealth(sessionId: String) {
        queue.async { [self] in
            store.retryHealth(sessionId: sessionId, now: clock.now())
            runHealthCheck(sessionId)
        }
    }

    /// "Repair hooks": ONLY on the person's click. Runs the existing installer (copies our hook, re-merges only our settings
    /// entries, keeps foreign ones; never restarts Cursor or a session), then re-checks every session that needs action.
    public func repairHooks(completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard !repairing, let script = hookSource?.appendingPathComponent("installer/install.sh"),
                  FileManager.default.isReadableFile(atPath: script.path) else { return DispatchQueue.main.async {
                      self.hookRepairError = "Bundled installer is unavailable or another repair is running. Reinstall the complete app, or wait and retry."
                      completion(false)
                  } }
            repairing = true
            log.write("\(stamp()) health repair started")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                guard Self.repairPythonAvailable(at: repairPythonExecutable) else {
                    queue.async { self.repairing = false }
                    return DispatchQueue.main.async {
                        self.hookRepairError = "Hook installation needs a working /usr/bin/python3 with JSON support. Ask your team to install the system Python tools, then retry. Homebrew-only Python is insufficient."
                        completion(false)
                    }
                }
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = [script.path]
                p.environment = ["HOME": paths.home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
                queue.async { [self] in
                    repairing = false
                    log.write("\(stamp()) health repair result=\(ok ? "ok" : "failed")")
                    for s in store.sessions.values where s.hookHealth.state == .actionRequired {
                        store.retryHealth(sessionId: s.id, now: clock.now()); runHealthCheck(s.id)
                    }
                    DispatchQueue.main.async {
                        self.hookRepairError = ok ? nil : "Hook installation failed. Check that ~/.claude/settings.json contains valid JSON and your user can write it; then retry. Existing settings are backed up before replacement."
                        completion(ok)
                    }
                }
            }
        }
    }

    /// Bound the prerequisite check: missing or broken developer tools must not leave setup waiting forever.
    static func repairPythonAvailable(at executable: URL = URL(fileURLWithPath: "/usr/bin/python3")) -> Bool {
        let p = Process(); p.executableURL = executable
        p.arguments = ["-I", "-c", "import json; assert json.loads('{\"ok\": true}')[\"ok\"] is True"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        guard (try? p.run()) != nil else { return false }
        guard finished.wait(timeout: .now() + 5) == .success else { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    /// One-shot timers only for sessions in a running check episode; cancelled once the outcome is resolved or action-required.
    private func scheduleHealthChecks() {
        guard running else { return }
        for (id, t) in healthTimers where store.sessions[id]?.hookHealth.nextCheckAt != t.at { t.item.cancel(); healthTimers[id] = nil }
        for s in store.sessions.values {
            guard let at = s.hookHealth.nextCheckAt, healthTimers[s.id] == nil else { continue }
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.running else { return }
                self.healthTimers[s.id] = nil
                self.runHealthCheck(s.id)
            }
            healthTimers[s.id] = (at, item)
            queue.asyncAfter(deadline: .now() + max(0, at.timeIntervalSince(clock.now())), execute: item)
        }
    }

    /// Core queue. Also the test seam for one check run.
    func runHealthCheck(_ sessionId: String) {
        guard let s = store.sessions[sessionId], s.hookHealth.state == .checking || s.hookHealth.state == .reconnecting else { return }
        let finding = diagnose(s)
        store.applyHealth(sessionId: sessionId, finding, now: clock.now())
        log.write(Daemon.healthAudit(stamp: stamp(), sessionId: safe(sessionId), finding: finding))
        changed()
    }

    static func healthAudit(stamp: String, sessionId: String, finding: HookHealth.Finding) -> String {
        let f: String
        switch finding {
        case .ok: f = "ok"
        case .reconnected: f = "reconnected"
        case .action(let c):
            switch c {
            case .listenerUnavailable: f = "action:listenerUnavailable"
            case .hooksNotRegistered: f = "action:hooksNotRegistered"
            case .hookScriptMissing: f = "action:hookScriptMissing"
            case .hookScriptOutdated: f = "action:hookScriptOutdated"
            case .extensionChanged: f = "action:extensionChanged"
            case .sessionNotHooked: f = "action:sessionNotHooked"
            }
        }
        return "\(stamp) health session=\(sessionId) finding=\(f)"
    }

    /// Read-only checks; the only writes are AgentDeck-internal and reversible (re-listen on our socket, re-arm the tailer).
    private func diagnose(_ s: Session) -> HookHealth.Finding {
        var reconnected = false
        if !HookDiagnostics.socketAccepts(paths.socket.path) {
            let fresh = SocketServer(path: paths.socket.path, queue: queue, handler: { [unowned self] in route($0, $1) })
            do {
                try fresh.start()
                retiredServers.append(server); server = fresh; reconnected = true
            } catch { return .action(.listenerUnavailable) }
        }
        if let p = s.transcriptPath, !tailer.isTracking(sessionId: s.id, path: p) { tailer.track(sessionId: s.id, path: p); reconnected = true }
        if !HookDiagnostics.registered(settings: HookDiagnostics.settings(home: paths.home)) { return .action(.hooksNotRegistered) }
        if let c = HookDiagnostics.scriptProblem(at: HookDiagnostics.hookScript(home: paths.home),
                                                 bundled: hookSource?.appendingPathComponent("hooks/adeck-hook")) { return .action(c) }
        if let running = runningVersion(s.pid), let recorded = HookDiagnostics.recordedVersion(capabilities: paths.capabilities), running != recorded {
            return .action(.extensionChanged(running))
        }
        return reconnected ? .reconnected : .ok
    }

    /// Test seam: one-shot health checks currently scheduled (core queue).
    var pendingHealthChecks: Int { healthTimers.count }

    /// Test seam: the Claude Code version a session's process runs (native-binary path), nil when unknown.
    var runningVersion: (Int32?) -> String? = { HookDiagnostics.runningVersion(pid: $0) }

    // MARK: routing (core queue)

    private func meta(_ req: HTTPRequest) -> HookMeta {
        func header(_ k: String) -> String? { req.headers[k].flatMap { $0.isEmpty ? nil : $0 } }
        // Amendment A1: an unresolvable pid is unknown (nil), never dead.
        let pid = header("x-adeck-pid").flatMap { Int32($0) }.flatMap(resolvePid)
        return HookMeta(pid: pid, host: header("x-adeck-host"), entrypoint: header("x-adeck-entry"))
    }

    private func route(_ req: HTTPRequest, _ conn: Connection) {
        let path = req.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? req.path
        let parts = path.split(separator: "/").map(String.init)
        let m = meta(req)
        if req.method == "POST", parts.count == 3, parts[0] == "v1", parts[1] == "event" {
            let name = parts[2]
            if let hook = HookKind(rawValue: name), Self.eventHooks.contains(hook), let input = try? HookInput.decode(req.body) {
                logRoute("event", name, input, verb: "-")
                ingest(Ingest.event(hook, input, meta: m, now: clock.now()))
            }
            conn.respond(status: 204, body: Data(), contentType: nil)
        } else if req.method == "POST", parts == ["v1", "gate", "PreToolUse"] || parts == ["v1", "decide", "PermissionRequest"] {
            let gate = parts[1] == "gate", hook: HookKind = gate ? .preToolUse : .permissionRequest
            guard let input = try? HookInput.decode(req.body) else { return reply(conn, .pass) }
            ingest(Ingest.event(hook, input, meta: m, now: clock.now()))
            let verb = gate ? broker.gate(input, meta: m) : broker.decide(input, meta: m)
            refreshTimers()   // A hold needs its timeout even before a waiter attaches.
            let word = verb.wireBody.split(separator: " ").first.map(String.init) ?? "-"
            logRoute(parts[1], hook.rawValue, input, verb: word + ((gate ? broker.lastPassReason : nil).map { " reason=\(safe($0))" } ?? ""))
            reply(conn, verb)
        } else if req.method == "GET", parts.count == 3, parts[0] == "v1", parts[1] == "wait" {
            let id = parts[2]
            // The hook's own shell pid (older hooks send none: no liveness, previous behaviour). 0/1/negative are never a hook.
            let hookPid = req.headers["x-adeck-hook-pid"].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil }
            // onClose is wired only by start(), so a rejected second wait can never close the real hold.
            let s = WaitStream(connection: conn, queue: queue, onClosed: { [weak self] in self?.broker.waiterClosed(id: id) })
            if broker.attach(id: id, waiter: s, hookPid: hookPid) { s.start() } else { conn.respond(status: 404, body: Data(), contentType: nil) }
        } else {
            conn.respond(status: 404, body: Data(), contentType: nil)
        }
    }

    private func reply(_ conn: Connection, _ verb: GateVerb) {
        conn.respond(status: 200, body: Data(verb.wireBody.utf8), contentType: "text/plain; charset=utf-8")
    }

    private func ingest(_ e: AgentEvent) {
        if let p = e.transcriptPath, !e.sessionId.isEmpty { tailer.track(sessionId: e.sessionId, path: p) }
        store.apply(e)
        broker.observe(e)
        if store.sessions[e.sessionId]?.state == .ended { tailer.untrack(sessionId: e.sessionId) }
        if case .hook(.stop) = e.kind, let s = store.sessions[e.sessionId] { summarize(s) }
        changed()
    }

    /// Never on the decision path. The line becomes the title only while the session has none (build doc, broker Open issue 5).
    private func summarize(_ s: Session) {
        summarizer?.request(session: s) { [weak self] line in
            guard let line else { return }
            self?.queue.async {
                guard let self, self.running, let cur = self.store.sessions[s.id], cur.title == nil else { return }
                // Stamped at the session's last event so a late summary never counts as new activity.
                self.store.apply(AgentEvent(sessionId: s.id, kind: .transcriptTitle, text: line, ts: cur.lastEventAt))
                self.changed()
            }
        }
    }

    private func brokerEmitted(_ e: AgentEvent) {
        store.apply(e)
        emitObserver?(e)
        if case .requestUpdated(let id, let status) = e.kind { log.write("\(stamp()) request \(id) \(status.rawValue)") }
        changed()
    }

    private func changed() {
        refreshTimers()
        scheduleHealthChecks()
        guard running, !changeScheduled else { return }
        changeScheduled = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            changeScheduled = false
            guard running else { return }
            let sessions = store.ordered
            try? SnapshotIO.save(sessions.filter { $0.state != .ended }, to: paths.snapshot)   // shortcut: one small file per coalesced change
            let cb = _onChange
            DispatchQueue.main.async { cb?(sessions) }
        }
    }

    // MARK: log (metadata only: never tool input, prompts or messages)

    private func stamp() -> String { ISO8601DateFormatter().string(from: clock.now()) }
    private func safe(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(64).map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? $0 : "?" }))
    }
    private func logRoute(_ route: String, _ hook: String, _ input: HookInput, verb: String) {
        log.write("\(stamp()) \(route) \(hook) session=\(safe(input.sessionId)) tool=\(safe(input.toolName)) verb=\(verb)")
    }
}
