import Foundation

public enum Presence: String, Sendable { case present, away }

public struct PresenceSnapshot: Equatable, Sendable {
    public var frontmostBundleId: String?
    public var idleSeconds: Double
    public var at: Date
    public init(frontmostBundleId: String?, idleSeconds: Double, at: Date) {
        self.frontmostBundleId = frontmostBundleId; self.idleSeconds = idleSeconds; self.at = at
    }
}
