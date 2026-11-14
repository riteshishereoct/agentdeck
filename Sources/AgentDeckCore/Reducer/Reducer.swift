import Foundation

public enum Reducer {
    public static let quietAfter: TimeInterval = 1800

    public static func apply(_ session: Session?, _ event: AgentEvent) -> Session {
        var s = session ?? Session(id: event.sessionId, startedAt: event.ts, lastEventAt: event.ts)
        if session == nil { update(&s, cwd: event.cwd) }

        if case .tick = event.kind {
            if [.working, .error, .waitingInCursor].contains(s.state), event.ts.timeIntervalSince(s.lastEventAt) >= quietAfter {
                s.state = .quiet
                retire(&s, finishedAt: nil) // Silence makes the old action unconfirmed, not still running.
            }
            return s
        }

        if s.state == .ended {
            // An ended session only revives on a newer hook (not SessionEnd) or a new held request.
            guard let endedAt = s.endedAt, event.ts > endedAt else { return s }
            switch event.kind {
            case .hook(let k) where k != .sessionEnd: break
            case .requestHeld: break
            default: return s
            }
            s.state = .idle; s.endedAt = nil
        }

        if let c = event.cwd { update(&s, cwd: c) }
        if case .hook(.sessionStart) = event.kind, let c = event.cwd, !c.isEmpty { s.workspaceRoot = c }   // the session's own folder wins over a first-seen cwd
        if let v = event.transcriptPath { s.transcriptPath = v }
        if let v = event.pid { s.pid = v }
        if let v = event.host { s.host = v }
        if let v = event.entrypoint { s.entrypoint = v }
        if let v = event.model { s.model = v }

        var stale = false
        var wake = true
        switch event.kind {
        case .hook: stale = event.ts < s.lastEventAt; wake = !stale
        case .transcriptToolUse, .transcriptToolResult, .transcriptAssistant, .transcriptTitle, .transcriptTasks: wake = event.ts > s.lastEventAt
        default: break
        }
        if case .transcriptTitle = event.kind {   // label only: a (re)written ai-title is not activity (tailer stamps it "now")
            if let t = event.text { s.title = t }
            return s
        }
        if wake && s.state == .quiet { s.state = .working }
        shiftActivity(&s, to: event.ts)
        s.lastEventAt = max(s.lastEventAt, event.ts)

        switch event.kind {
        case .hook(let k): applyHook(&s, k, event, stale: stale)
        case .requestHeld(let r):
            if !s.pending.contains(where: { $0.id == r.id }) { s.pending.append(r) }
            s.state = .needsYou
        case .requestUpdated(let id, let status): applyRequestUpdate(&s, id: id, status: status)
        case .pidGone: end(&s, at: event.ts)
        case .transcriptTasks(let p): s.progress = p.total > 0 ? p : nil
        case .transcriptTitle: break   // handled above
        case .transcriptToolResult:
            if let id = event.toolUseId, s.currentStep?.toolUseId == id { retire(&s, finishedAt: event.ts) }
        case .transcriptToolUse, .transcriptAssistant, .tick: break   // tool_use feeds hooksDegraded in SessionStore; model is set above
        }
        return s
    }

    /// 30 one-minute buckets, newest last; the sparkline advances on events only (tick leaves it alone).
    /// Moves the current step to `lastStep` (G-NOW); nil `finishedAt` = no finish was observed.
    private static func retire(_ s: inout Session, finishedAt: Date?) {
        guard var step = s.currentStep else { return }
        step.finishedAt = finishedAt
        s.lastStep = step; s.currentStep = nil
    }

    private static func shiftActivity(_ s: inout Session, to ts: Date) {
        let d = Int(ts.timeIntervalSince1970 / 60) - Int(s.lastEventAt.timeIntervalSince1970 / 60)
        guard d > 0 else { return }
        let n = min(d, s.activity.count)
        s.activity.removeFirst(n); s.activity.append(contentsOf: Array(repeating: 0, count: n))
    }

    private static let maxSubagents = 50

    private static func agentIndex(_ s: Session, _ id: String?) -> Int? {
        id.flatMap { id in s.subagents.firstIndex { $0.id == id } }
    }

    private static func applySubagent(_ s: inout Session, _ k: HookKind, _ e: AgentEvent) {
        guard let id = e.agentId else { return }
        if k == .subagentStart {
            guard let type = e.agentType, !type.isEmpty else { return }   // internal agents are hidden
            if let i = agentIndex(s, id) { s.subagents[i].type = type }
            else { s.subagents.append(Agent(id: id, type: type, startedAt: e.ts)) }
        } else if let i = agentIndex(s, id) {
            s.subagents[i].state = .ended; s.subagents[i].endedAt = e.ts; s.subagents[i].currentStep = nil
            s.subagents[i].summary = twoLines(e.text)
        }
        while s.subagents.count > maxSubagents, let old = s.subagents.firstIndex(where: { $0.state == .ended }) { s.subagents.remove(at: old) }
    }

    /// Tool events of a known subagent update its row; the session keeps only its step count (and, via the caller, the activity tick).
    private static func applyAgentTool(_ s: inout Session, _ i: Int, _ k: HookKind, _ e: AgentEvent, stale: Bool) {
        switch k {
        case .preToolUse:
            s.stepCount += 1; s.subagents[i].stepCount += 1
            if !stale { s.subagents[i].currentStep = Step(label: e.inputPreview ?? e.tool ?? "", tool: e.tool ?? "", toolUseId: e.toolUseId, startedAt: e.ts) }
        case .postToolUse, .permissionDenied: if matches(s.subagents[i].currentStep, e.toolUseId) { s.subagents[i].currentStep = nil }
        default: if matches(s.subagents[i].currentStep, e.toolUseId) { s.subagents[i].currentStep?.failed = true }   // postToolUseFailure
        }
    }

    private static func update(_ s: inout Session, cwd: String?) {
        guard let cwd else { return }
        s.cwd = cwd
        if s.workspaceRoot == nil, !cwd.isEmpty { s.workspaceRoot = cwd }
        if s.project.isEmpty { s.project = cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent }
    }

    private static func end(_ s: inout Session, at ts: Date) {
        s.state = .ended; s.endedAt = ts; s.pending = []; retire(&s, finishedAt: ts)
    }

    private static func resumeState(_ s: Session) -> SessionState {
        if s.pending.contains(where: { $0.status == .pending }) { return .needsYou }
        return s.failureStreak >= 3 ? .error : .working
    }

    private static func matches(_ step: Step?, _ id: String?) -> Bool {
        guard let step else { return false }
        return step.toolUseId == nil || id == nil || step.toolUseId == id
    }

    private static func applyHook(_ s: inout Session, _ k: HookKind, _ e: AgentEvent, stale: Bool) {
        if [.preToolUse, .postToolUse, .postToolUseFailure, .permissionDenied].contains(k), let i = agentIndex(s, e.agentId) {
            if k == .preToolUse, !s.activity.isEmpty { s.activity[s.activity.count - 1] += 1 }
            applyAgentTool(&s, i, k, e, stale: stale); return
        }
        switch k {
        case .userPromptSubmit:
            if let line = firstLine(SessionLabels.goal(e.text)) {
                if SessionLabels.goal(s.goal) == nil { s.goal = line } else { s.latestAsk = line }
            }
            if !stale { s.state = resumeState(s); s.summary = nil }
        case .preToolUse:
            s.stepCount += 1
            if !s.activity.isEmpty { s.activity[s.activity.count - 1] += 1 }
            if !stale {
                s.currentStep = Step(label: e.inputPreview ?? e.tool ?? "", tool: e.tool ?? "", toolUseId: e.toolUseId, startedAt: e.ts)
                s.state = resumeState(s)
            }
        case .postToolUse:
            s.failureStreak = 0
            if matches(s.currentStep, e.toolUseId) { retire(&s, finishedAt: e.ts) }
            if !stale { s.state = resumeState(s) }
        case .postToolUseFailure:
            s.failureStreak += 1
            if matches(s.currentStep, e.toolUseId) { s.currentStep?.failed = true }
            if !stale { s.state = resumeState(s) }
        case .permissionDenied:
            if matches(s.currentStep, e.toolUseId) { s.currentStep?.failed = true; retire(&s, finishedAt: e.ts) }
            if !stale { s.state = resumeState(s) }
        case .stop:
            if !stale {
                s.summary = twoLines(e.text); retire(&s, finishedAt: e.ts)
                if s.state != .needsYou { s.state = .yourTurn }
            }
        case .notification:
            if !stale, e.notificationType == "idle_prompt", s.state != .needsYou { s.state = .yourTurn }
        case .sessionEnd: end(&s, at: e.ts)
        case .subagentStart, .subagentStop: applySubagent(&s, k, e)
        case .sessionStart, .permissionRequest, .preCompact: break
        }
    }

    private static func applyRequestUpdate(_ s: inout Session, id: String, status: RequestStatus) {
        guard let i = s.pending.firstIndex(where: { $0.id == id }) else { return }
        if s.pending[i].channel == .notify, status == .timedOut {   // an expired notice (10 min): nothing is waiting on it any more
            s.pending.remove(at: i)
            if s.state == .needsYou, !s.pending.contains(where: { $0.status == .pending }) {
                s.state = s.pending.isEmpty ? .quiet : .waitingInCursor   // silent about it for 10 min; any newer event wakes it
            }
            return
        }
        switch status {
        case .allowed, .denied, .answered, .handledElsewhere, .hookGone: s.pending.remove(at: i)
        default: s.pending[i].status = status
        }
        guard s.state == .needsYou || s.state == .waitingInCursor else { return }
        if s.pending.contains(where: { $0.status == .pending }) { s.state = .needsYou }
        else if s.pending.contains(where: { $0.status == .movedToCursor || $0.status == .timedOut }) { s.state = .waitingInCursor }
        else { s.state = .working }
    }

    private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private static func firstLine(_ text: String?) -> String? {
        guard let l = lines(text).first else { return nil }
        return l.count > 80 ? String(l.prefix(79)) + "…" : l
    }
    private static func twoLines(_ text: String?) -> String? {
        let l = lines(text)
        return l.isEmpty ? nil : l.prefix(2).joined(separator: "\n")
    }
}
