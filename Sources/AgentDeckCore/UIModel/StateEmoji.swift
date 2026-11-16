import Foundation

/// Emoji + motion shown for each session state. Pure data so it is testable.
public struct StateEmoji: Equatable, Sendable {
    public enum Motion: Equatable, Sendable { case none, pulse, spin, bounce, shake, float }

    public let emoji: String
    /// Accessibility label.
    public let label: String
    public let motion: Motion

    /// Only working and needsYou loop; every other state plays once on change, then rests.
    public var continuous: Bool { motion == .pulse || motion == .spin }

    /// Loops are drawn from a capped timeline: a SwiftUI repeatForever animation ticks at display rate (120 Hz on ProMotion).
    public static let loopInterval: TimeInterval = 1.0 / 15.0
    /// Loops run this long after a state change, then rest: each tick re-renders the glass panel.
    public static let loopSeconds: TimeInterval = CompanionPolicy.reactionSeconds

    /// Pose of a looping motion at time `t` seconds: spin turns once per 2.4 s; pulse eases 1 → 1.2 → 1 every 1.6 s.
    public static func loopPose(_ motion: Motion, at t: TimeInterval) -> (scale: Double, angle: Double) {
        switch motion {
        case .spin: return (1, t.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)
        case .pulse: return (1 + 0.1 * (1 - cos(2 * .pi * t.truncatingRemainder(dividingBy: 1.6) / 1.6)), 0)
        default: return (1, 0)
        }
    }

    /// The state the collapsed pill shows: the most urgent live state, same priority as PillSummary's colour.
    public static func pillState(_ sessions: [Session]) -> SessionState {
        let live = Set(sessions.map(\.state))
        return [.needsYou, .error, .yourTurn, .working, .waitingInCursor].first(where: live.contains) ?? .idle
    }

    public static func `for`(_ state: SessionState) -> StateEmoji {
        switch state {
        case .working: return .init(emoji: "⚙️", label: "Working", motion: .spin)
        case .needsYou: return .init(emoji: "✋", label: "Needs you", motion: .pulse)
        case .waitingInCursor: return .init(emoji: "👀", label: "Waiting in Cursor", motion: .float)
        case .yourTurn: return .init(emoji: "✅", label: "Ready for you", motion: .bounce)
        case .error: return .init(emoji: "⚠️", label: "Error", motion: .shake)
        case .idle: return .init(emoji: "💤", label: "Idle", motion: .float)
        case .quiet: return .init(emoji: "🔕", label: "Quiet", motion: .none)
        case .ended: return .init(emoji: "🏁", label: "Ended", motion: .none)
        }
    }
}
