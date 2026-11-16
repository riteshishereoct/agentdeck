import Foundation

public enum CompanionStyle: String, Codable, CaseIterable, Sendable {
    case pet, geometry, off
}

public enum CompanionMood: String, CaseIterable, Sendable {
    case sleeping, calm, busy, alert, happy, upset

    public static func from(state: SessionState) -> CompanionMood {
        switch state {
        case .needsYou: return .alert
        case .error: return .upset
        case .yourTurn: return .happy
        case .working: return .busy
        case .waitingInCursor: return .calm
        case .idle, .quiet, .ended: return .sleeping
        }
    }

    /// Same priority as the pill (`StateEmoji.pillState`).
    public static func from(sessions: [Session]) -> CompanionMood { from(state: StateEmoji.pillState(sessions)) }

    public var label: String { rawValue }
}

/// Energy policy: no frames are scheduled unless this says so, so an idle companion costs zero CPU.
public enum CompanionPolicy {
    public static let frameInterval: TimeInterval = 1.0 / 30.0
    /// Busy can last for hours while the panel is visible, so it draws at half rate.
    public static func frameInterval(for mood: CompanionMood) -> TimeInterval { mood == .busy ? 1.0 / 15.0 : frameInterval }
    /// Short reaction window after a mood change (happy/upset/sleep transitions).
    public static let reactionSeconds: TimeInterval = 4

    public static func shouldAnimate(style: CompanionStyle, mood: CompanionMood, visible: Bool, enabled: Bool,
                                     hovering: Bool, secondsSinceMoodChange: TimeInterval) -> Bool {
        guard visible, enabled, style != .off else { return false }
        // No mood loops forever: each tick re-renders the whole glass panel (measured ~28% of a core while alert).
        return hovering || secondsSinceMoodChange < reactionSeconds
    }
}
