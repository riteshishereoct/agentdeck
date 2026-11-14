import Foundation

public enum RequestKind: String, Codable, Sendable { case permission, question, planReview }

public enum RiskLevel: String, Codable, Comparable, Sendable {
    case low, med, high
    private var rank: Int { switch self { case .low: return 0; case .med: return 1; case .high: return 2 } }
    public static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rank < b.rank }
}

public struct Risk: Equatable, Sendable {
    public var level: RiskLevel
    public var reason: String
    public init(level: RiskLevel, reason: String) { self.level = level; self.reason = reason }
}

public enum RequestStatus: String, Codable, Sendable {
    case pending, allowed, denied, answered, movedToCursor, timedOut, handledElsewhere, hookGone
}

public struct Request: Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionId: String
    public let agentId: String?
    public let kind: RequestKind
    public let hook: HookKind
    public let tool: String
    public let toolUseId: String?
    public let preview: String
    public let fullInput: JSONValue
    public let risk: Risk
    public let suggestions: [JSONValue]
    public let personOnly: Bool
    public let channel: Channel
    public let createdAt: Date
    public var status: RequestStatus

    public init(id: String, sessionId: String, agentId: String? = nil, kind: RequestKind, hook: HookKind, tool: String,
                toolUseId: String? = nil, preview: String, fullInput: JSONValue, risk: Risk, suggestions: [JSONValue] = [],
                personOnly: Bool = false, channel: Channel, createdAt: Date, status: RequestStatus = .pending) {
        self.id = id; self.sessionId = sessionId; self.agentId = agentId; self.kind = kind; self.hook = hook; self.tool = tool
        self.toolUseId = toolUseId; self.preview = preview; self.fullInput = fullInput; self.risk = risk
        self.suggestions = suggestions; self.personOnly = personOnly; self.channel = channel; self.createdAt = createdAt
        self.status = status
    }
}
