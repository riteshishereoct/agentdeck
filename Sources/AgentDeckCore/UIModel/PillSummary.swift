import Foundation

public enum PillColor: String, Equatable { case grey, blue, amber, green, red }

public struct PillSummary: Equatable {
    public var text: String
    public var color: PillColor
    public init(text: String, color: PillColor) { self.text = text; self.color = color }

    /// Counts active work only. idle/quiet sessions are a muted "N idle", never "agents"; ended sessions are not counted.
    public static func make(_ sessions: [Session]) -> PillSummary {
        let live = sessions.filter { $0.state != .ended }
        guard !live.isEmpty else { return PillSummary(text: "No agents", color: .grey) }
        func n(_ s: SessionState) -> Int { live.filter { $0.state == s }.count }
        let idle = n(.idle) + n(.quiet)
        let parts = [("needs you", n(.needsYou)), ("error", n(.error)), ("ready for you", n(.yourTurn)), ("working", n(.working)),
                     ("waiting in Cursor", n(.waitingInCursor))]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        guard !parts.isEmpty else { return PillSummary(text: "Idle · \(idle) session\(idle == 1 ? "" : "s")", color: .grey) }
        let color: PillColor = n(.needsYou) > 0 ? .amber : n(.error) > 0 ? .red : n(.yourTurn) > 0 ? .green
            : n(.working) > 0 ? .blue : .amber
        return PillSummary(text: (parts + (idle > 0 ? ["\(idle) idle"] : [])).joined(separator: " · "), color: color)
    }
}
