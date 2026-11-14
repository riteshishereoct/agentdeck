import Foundation

public enum AttentionStage: Equatable { case expandGlow, pulse, notify, waitingInCursor }
public enum AttentionLadder {
    public static let pulseAt: TimeInterval = 30, notifyAt: TimeInterval = 90, cursorAt: TimeInterval = 590
    public static func stage(age: TimeInterval) -> AttentionStage {
        if age >= cursorAt { return .waitingInCursor }
        if age >= notifyAt { return .notify }
        if age >= pulseAt { return .pulse }
        return .expandGlow
    }
}
public struct AttentionTracker {
    private var announced = Set<String>()
    public init() {}
    public mutating func dueForNotification(_ requests: [Request], mutedIds: Set<String>, quiet: Bool, now: Date) -> [Request] {
        announced.formIntersection(Set(requests.filter { $0.status == .pending }.map(\.id)))
        guard !quiet else { return [] }
        let due = requests.filter {
            $0.status == .pending && !mutedIds.contains($0.id) && !announced.contains($0.id) &&
            AttentionLadder.stage(age: now.timeIntervalSince($0.createdAt)) == .notify
        }
        announced.formUnion(due.map(\.id))
        return due
    }
    public func pulsing(_ requests: [Request], mutedIds: Set<String>, now: Date) -> Bool {
        requests.contains { $0.status == .pending && !mutedIds.contains($0.id) && AttentionLadder.stage(age: now.timeIntervalSince($0.createdAt)) == .pulse }
    }
}
public enum NotificationPlan {
    public static let decideCategory = "AGENTDECK_DECIDE", noticeCategory = "AGENTDECK_NOTICE"
    public static let denyActionId = "deny", showActionId = "show"
    public static func category(for r: Request) -> String { r.channel == .notify || r.kind == .planReview ? noticeCategory : decideCategory }
    public static func actionIds(forCategory c: String) -> [String] {
        if c == decideCategory { return [denyActionId, showActionId] }
        return c == noticeCategory ? [showActionId] : []
    }
    public static func userInfo(for r: Request) -> [String: String] { ["requestId": r.id, "sessionId": r.sessionId] }
    public static func requestId(from userInfo: [AnyHashable: Any]) -> String? { userInfo["requestId"] as? String }
    public static func content(for r: Request, session: Session?, sessionIndex: Int, privacy: Bool) -> (title: String, body: String) {
        if privacy { return ("Session \(sessionIndex) needs approval", CardFormat.displayTool(r.tool)) }
        return ("\(session?.project ?? "Session") needs approval", String(CardFormat.headline(r).prefix(80)))
    }
}
