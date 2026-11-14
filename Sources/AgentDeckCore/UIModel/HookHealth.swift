import Foundation

/// Per-session hook health (docs/hook-health.md). Pure: the store feeds evidence, the daemon feeds check findings.
/// Healthy/recovered come ONLY from a fresh PreToolUse of that session; missed history is counted, never replayed or hidden.
public struct HookHealth: Equatable, Sendable {
    public enum State: String, Sendable { case healthy, checking, reconnecting, recovered, actionRequired }

    /// What the person must do; AgentDeck cannot fix these by itself.
    public enum Cause: Equatable, Sendable {
        case listenerUnavailable                // our socket could not be restarted
        case hooksNotRegistered                 // ~/.claude/settings.json lacks AgentDeck's entries
        case hookScriptMissing                  // ~/.agentdeck/bin/adeck-hook missing or not executable
        case hookScriptOutdated                 // differs from the bundled hooks/adeck-hook
        case extensionChanged(String)           // the session runs another Claude Code version than the one measured
        case sessionNotHooked                   // every check passes, yet this session's tools keep running without hooks
    }

    /// Result of one read-only check run (plus any AgentDeck-internal fix it made).
    public enum Finding: Equatable, Sendable { case ok, reconnected, action(Cause) }

    /// Re-check delays after a miss; then the episode stops (no endless or idle polling).
    public static let backoff: [TimeInterval] = [5, 30, 120]

    public private(set) var state: State = .healthy
    /// Tool calls that ran (a transcript result exists) with no PreToolUse for this session, not resolved by a late one.
    public private(set) var missed = 0
    public private(set) var lastHookAt: Date?
    public private(set) var cause: Cause?
    /// When the daemon should run the next check; nil = no timer (healthy, recovered, action required, or waiting for evidence).
    public private(set) var nextCheckAt: Date?
    private var attempt = 0
    private var episodeMisses = 0
    private var recoverySince: Date?

    public init() {}

    /// Shown at all (badge) unless healthy.
    public var degraded: Bool { state != .healthy }

    /// A PreToolUse for this session: the only evidence that hooks reach AgentDeck.
    mutating func hook(at ts: Date) {
        lastHookAt = max(lastHookAt ?? ts, ts)
        guard state != .healthy, recoverySince.map({ ts >= $0 }) ?? true else { return }
        state = missed > 0 ? .recovered : .healthy
        cause = nil; nextCheckAt = nil; attempt = 0; episodeMisses = 0
    }

    /// The PreToolUse of a tool already counted as missed arrived after all: that miss is resolved (late, not lost).
    mutating func lateHook(at ts: Date) {
        guard recoverySince.map({ ts >= $0 }) ?? true else { return }
        missed = max(0, missed - 1)
        if state == .recovered && missed == 0 { state = .healthy }
        hook(at: ts)
    }

    /// A confirmed miss. Starts a check episode unless one is running; after a clean episode another miss needs the person.
    mutating func miss(now: Date) {
        missed += 1; episodeMisses += 1
        switch state {
        case .healthy, .recovered:
            state = .checking; cause = nil; attempt = 0; episodeMisses = 1; nextCheckAt = now; recoverySince = now
        case .checking where nextCheckAt == nil && attempt >= Self.backoff.count:
            state = .actionRequired; cause = .sessionNotHooked
        default: break
        }
    }

    /// Apply one check run. Ignored unless an episode is running (a late result never overrides fresh evidence).
    mutating func apply(_ finding: Finding, now: Date) {
        guard state == .checking || state == .reconnecting else { return }
        if case .action(let c) = finding { state = .actionRequired; cause = c; nextCheckAt = nil; return }
        if attempt < Self.backoff.count {
            state = finding == .reconnected ? .reconnecting : .checking
            nextCheckAt = now.addingTimeInterval(Self.backoff[attempt]); attempt += 1
        } else if episodeMisses > 1 {
            state = .actionRequired; cause = .sessionNotHooked; nextCheckAt = nil
        } else {
            state = .checking; nextCheckAt = nil      // checks passed; the next tool call decides (no timer)
        }
    }

    /// "Check connection" / "Retry": a new bounded episode. Never touches requests, never marks healthy.
    mutating func retry(now: Date) {
        guard state != .healthy, state != .recovered else { return }
        state = .checking; cause = nil; attempt = 0; episodeMisses = 0; nextCheckAt = now
    }

    // MARK: text (short; RowDetail exposes it)

    public var badge: String? {
        switch state {
        case .healthy: return nil
        case .checking: return "hooks: checking"
        case .reconnecting: return "hooks: reconnecting"
        case .recovered: return "hooks recovered"
        case .actionRequired: return "hooks: action needed"
        }
    }

    public var explanation: String? {
        let missedText = missed == 0 ? "" : " \(missed) earlier step\(missed == 1 ? " was" : "s were") not seen."
        switch state {
        case .healthy: return nil
        case .checking:
            return nextCheckAt == nil ? "Checks passed; waiting for the next tool call to confirm hooks." + missedText
                                      : "AgentDeck may miss approvals or steps for this session. Checking…" + missedText
        case .reconnecting: return "AgentDeck may miss approvals or steps for this session. Reconnecting…" + missedText
        case .recovered: return "Hooks are reaching AgentDeck again." + missedText
        case .actionRequired: return (cause.map(Self.action) ?? "Restart the Claude tab to reload hooks.") + missedText
        }
    }

    public static func action(_ c: Cause) -> String {
        switch c {
        case .listenerUnavailable: return "AgentDeck could not restore its connection. Click Check connection; if it still fails, restart AgentDeck."
        case .hooksNotRegistered: return "AgentDeck hooks are missing from ~/.claude/settings.json. Click Repair hooks."
        case .hookScriptMissing: return "The AgentDeck hook script is missing or not executable. Click Repair hooks."
        case .hookScriptOutdated: return "The installed AgentDeck hook is out of date. Click Repair hooks."
        case .extensionChanged(let v): return "Claude Code updated to \(v); restart the Claude tab to load hooks."
        case .sessionNotHooked: return "This session is not sending hooks. Restart the Claude tab to reload them."
        }
    }

    /// Repair is offered only where reinstalling our own hook entries can help.
    public var offersRepair: Bool {
        guard state == .actionRequired, let c = cause else { return false }
        return [.hooksNotRegistered, .hookScriptMissing, .hookScriptOutdated].contains(c)
    }
    public var offersRetry: Bool { state == .actionRequired || (state == .checking && nextCheckAt == nil) }
}
