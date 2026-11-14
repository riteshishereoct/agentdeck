import Foundation

/// Not thread-safe: call on the core queue.
public final class SessionStore {
    public static let endedRetention: TimeInterval = 120

    /// Tool calls made before this (while AgentDeck was not running) failed open by design; they never mean hooks are degraded.
    private let launchedAt: Date?
    public init(launchedAt: Date? = nil) { self.launchedAt = launchedAt }
    public private(set) var sessions: [String: Session] = [:]

    // Hook health side tables (the reducer stays pure). A miss = a transcript tool_use that RAN (its tool_result exists) with no
    // PreToolUse for it. Claude Code writes every tool_use of a multi-tool message at once but fires each PreToolUse only when
    // that tool starts, after its siblings finish (live 2026-11-14: 5-36 s late), so the clock starts at the result, not the use.
    // An error result proves nothing: validation errors, interrupts and native denials never fire PreToolUse.
    private static let degradedAfter: TimeInterval = 5
    private static let historyWindow: TimeInterval = 30
    private static let seenPreCap = 1024
    private static let suspectCap = 1024
    private var latestNow: Date?
    private var seenPre = Set<String>()
    private var seenPreOrder: [String] = []
    private struct Suspect { let session: String; let since: Date; var resultAt: Date? }
    private var suspects: [String: Suspect] = [:]
    private var missedIds: [String: String] = [:]   // toolUseId -> session, for late PreToolUse resolution

    public func apply(_ event: AgentEvent) {
        let previousNow = latestNow
        latestNow = max(latestNow ?? event.ts, event.ts)
        if case .tick = event.kind {
            for (id, s) in sessions {
                let next = Reducer.apply(s, event)
                if next.state == .ended, let end = next.endedAt, event.ts.timeIntervalSince(end) >= Self.endedRetention {
                    sessions[id] = nil
                    suspects = suspects.filter { $0.value.session != id }
                    missedIds = missedIds.filter { $0.value != id }
                } else {
                    sessions[id] = next
                }
            }
            for (toolUseId, s) in suspects {
                guard let r = s.resultAt, event.ts.timeIntervalSince(r) >= Self.degradedAfter else { continue }
                suspects[toolUseId] = nil
                guard sessions[s.session] != nil else { continue }
                missedIds[toolUseId] = s.session
                health(s.session) { $0.miss(now: event.ts) }
            }
            return
        }
        switch event.kind {
        case .hook(.preToolUse):
            if let id = event.toolUseId { notePre(id, session: event.sessionId, at: event.ts) }
            else if sessions[event.sessionId] != nil { health(event.sessionId) { $0.hook(at: event.ts) } }
        case .transcriptToolUse:
            if let raw = event.toolUseId, sessions[event.sessionId] != nil, !seenPre.contains(key(raw, session: event.sessionId)), launchedAt.map({ event.ts >= $0 }) ?? true,
               previousNow.map({ event.ts >= $0.addingTimeInterval(-Self.historyWindow) }) ?? true, suspects.count < Self.suspectCap {
                suspects[key(raw, session: event.sessionId)] = Suspect(session: event.sessionId, since: event.ts)
            }
        case .transcriptToolResult(let isError):
            if let raw = event.toolUseId {
                let id = key(raw, session: event.sessionId)
                if isError { suspects[id] = nil } else { suspects[id]?.resultAt = event.ts }
            }
        default: break
        }
        switch event.kind {   // transcript lines never create a session (they may be history of one we never saw)
        case .transcriptToolUse, .transcriptToolResult, .transcriptAssistant, .transcriptTitle, .transcriptTasks:
            if sessions[event.sessionId] == nil { return }
        default: break
        }
        sessions[event.sessionId] = Reducer.apply(sessions[event.sessionId], event)
        if case .hook(.preToolUse) = event.kind, sessions[event.sessionId]?.hookHealth.lastHookAt == nil {
            health(event.sessionId) { $0.hook(at: event.ts) }   // the session was created by this very event
        }
    }

    /// Only this session's own PreToolUse counts as evidence; another session's events never clear it.
    private func key(_ id: String, session: String) -> String { session + "\0" + id }

    private func notePre(_ raw: String, session: String, at ts: Date) {
        let id = key(raw, session: session)
        suspects[id] = nil
        if missedIds[id] == session { missedIds[id] = nil; health(session) { $0.lateHook(at: ts) } }
        else if sessions[session] != nil { health(session) { $0.hook(at: ts) } }
        guard seenPre.insert(id).inserted else { return }
        seenPreOrder.append(id)
        if seenPreOrder.count > Self.seenPreCap { seenPre.remove(seenPreOrder.removeFirst()) }
    }

    private func health(_ session: String, _ change: (inout HookHealth) -> Void) {
        guard var s = sessions[session] else { return }
        change(&s.hookHealth)
        s.hooksDegraded = s.hookHealth.degraded
        sessions[session] = s
    }

    /// The daemon's check result for one session.
    public func applyHealth(sessionId: String, _ finding: HookHealth.Finding, now: Date) { health(sessionId) { $0.apply(finding, now: now) } }

    /// The person's "Check connection" / "Retry".
    public func retryHealth(sessionId: String, now: Date) { health(sessionId) { $0.retry(now: now) } }

    /// Seeds sessions loaded from the snapshot (no replay).
    public func restore(_ restored: [Session]) {
        for s in restored { sessions[s.id] = s }
    }

    public var ordered: [Session] {
        sessions.values.sorted {
            if ($0.state == .needsYou) != ($1.state == .needsYou) { return $0.state == .needsYou }
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            return $0.id < $1.id
        }
    }
}
