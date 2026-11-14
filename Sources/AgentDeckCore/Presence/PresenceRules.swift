import Foundation

public enum PresenceRules {
    public static func presence(host: String?, snapshot: PresenceSnapshot, settings: AppSettings) -> Presence {
        if settings.awayMode { return .away }
        guard let host, let front = snapshot.frontmostBundleId else { return .away }
        if snapshot.idleSeconds >= settings.awayThresholdSeconds { return .away }
        if settings.cursorBundleIds.contains(host) { return settings.cursorBundleIds.contains(front) ? .present : .away }
        return front == host ? .present : .away
    }
}
