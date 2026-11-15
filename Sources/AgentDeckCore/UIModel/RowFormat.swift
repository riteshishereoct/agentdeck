import Foundation

public enum SessionSource: Equatable { case ideExtension, cliTerminal, headless, unknown }

public enum RowFormat {
    static let hostNames = ["com.todesktop.230313mzl4w4u92": "Cursor", "com.microsoft.VSCode": "VS Code",
                            "com.googlecode.iterm2": "iTerm", "iTerm.app": "iTerm", "com.apple.Terminal": "Terminal",
                            "Apple_Terminal": "Terminal", "vscode": "VS Code terminal", "WarpTerminal": "Warp", "dev.warp.Warp-Stable": "Warp"]

    public static func hostName(_ host: String?) -> String? {
        guard let h = host, !h.isEmpty else { return nil }
        return hostNames[h] ?? h
    }

    /// Classified only from what the hooks/transcript actually reported (CLAUDE_CODE_ENTRYPOINT, host bundle id).
    public static func source(_ s: Session) -> SessionSource {
        guard let e = s.entrypoint, !e.isEmpty else { return .unknown }
        if e == "claude-vscode" || e.hasSuffix("-vscode") || e == "claude-desktop" { return .ideExtension }
        if e == "cli" { return .cliTerminal }
        if e.hasPrefix("sdk") { return .headless }
        return .unknown
    }

    /// Explicit adapter/source label. AgentDeck only tracks Claude Code via its hooks; nothing else is implied.
    public static func sourceLabel(_ s: Session) -> String {
        let host = hostName(s.host)
        switch source(s) {
        case .ideExtension: return "Claude Code · \(host.map { "\($0) extension" } ?? "IDE extension")"
        case .cliTerminal: return "Claude Code CLI · \(host.map { $0 == "Cursor" ? "Cursor terminal" : $0 } ?? "terminal")"
        case .headless: return "Claude Code headless (\(s.entrypoint ?? "sdk"))"
        case .unknown: return "Claude Code · \(host ?? "unknown host")"
        }
    }

    /// Distinguishes same-name sessions (same workspace, same goal) in rows and Open buttons.
    public static func shortId(_ s: Session) -> String { "#" + String(s.id.prefix(6)) }

    public static func title(_ s: Session) -> String {
        let text = SessionLabels.goal(s.title) ?? SessionLabels.goal(s.goal) ?? SessionLabels.goal(s.latestAsk)
        let project = s.project.isEmpty ? "unknown project" : s.project
        return "\(project) · \(text ?? "Goal unavailable")"
    }

    public static func sessionAge(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h " + String(format: "%02d", s % 3600 / 60) + "m"
    }

    public static func stepElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    public static func modelLabel(_ model: String?) -> String? {
        guard let m = SessionLabels.goal(model) else { return nil }
        let l = m.lowercased()
        return l.contains("opus") ? "Opus" : l.contains("sonnet") ? "Sonnet" : l.contains("haiku") ? "Haiku" : m
    }

    public static func stateText(_ s: Session, now: Date) -> String {
        switch s.state {
        case .idle: return "Idle · awaiting activity"
        case .quiet: return "No recent updates"
        case .working: return "working"
        case .needsYou: return "needs you"
        case .waitingInCursor: return "waiting in Cursor ↗"
        case .yourTurn: return "ready for you"
        case .error: return "error"
        case .ended: return "ended"
        }
    }

    /// G-NOW: "Now:" only for a step reported as running; otherwise "Last:" with the time it was last observed.
    /// Absolute clock times, so the text never goes stale between events and needs no timer.
    public static func stepLine(_ s: Session, now: Date) -> String? {
        if let c = s.currentStep, s.state != .quiet {
            if c.failed { return "Last: \(c.label) — failed (\(clock(c.startedAt)))" }
            // A step awaiting approval is not running (review M7).
            let verb = s.state == .needsYou || s.state == .waitingInCursor ? "Waiting" : "Now"
            return "\(verb): \(c.label) (since \(clock(c.startedAt)))"
        }
        guard let l = s.lastStep ?? s.currentStep else { return nil }
        return "Last: \(l.label)\(l.failed ? " — failed" : "") (\(clock(l.finishedAt ?? l.startedAt)))"
    }

    public static func clock(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) }
}
