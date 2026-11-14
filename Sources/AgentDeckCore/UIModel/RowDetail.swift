import Foundation

public enum ProgressDisplay: Equatable { case bar(done: Int, total: Int), steps(count: Int, spark: String) }
public enum RowDetail {
    public static func progress(_ s: Session) -> ProgressDisplay {
        if let p = s.progress, p.total > 0 { return .bar(done: p.done, total: p.total) }
        return .steps(count: s.stepCount, spark: sparkline(s.activity))
    }
    public static func sparkline(_ activity: [Int]) -> String {
        guard let peak = activity.max(), peak > 0 else { return "" }
        let levels = Array("▁▂▃▄▅▆▇█")
        return String(activity.map { levels[min(7, max(0, Int(Double(max(0, $0)) / Double(peak) * 7)))] })
    }
    public static func visibleSubagents(_ s: Session) -> [Agent] { s.subagents.filter { !$0.type.isEmpty } }
    public static func subagentLine(_ s: Session) -> String? {
        let agents = visibleSubagents(s)
        guard !agents.isEmpty else { return nil }
        return (["\(agents.count) subagent\(agents.count == 1 ? "" : "s")"] + agents.map { "\($0.type) \($0.state == .ended ? "○" : "●")" }).joined(separator: " · ")
    }
    public static func degradedBadge(_ s: Session) -> String? { s.hookHealth.badge ?? (s.hooksDegraded ? "hooks degraded" : nil) }
    /// One short line: what may be unavailable or what to do, then the last confirmed hook time. nil while healthy.
    public static func hookHealthLine(_ s: Session, timeZone: TimeZone = .current) -> String? {
        guard let text = s.hookHealth.explanation else { return nil }
        return text + " " + lastHook(s, timeZone: timeZone)
    }
    public static func lastHook(_ s: Session, timeZone: TimeZone = .current) -> String {
        guard let t = s.hookHealth.lastHookAt else { return "No hook seen yet." }
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = timeZone; f.locale = Locale(identifier: "en_US_POSIX")
        return "Last hook \(f.string(from: t))."
    }
}
