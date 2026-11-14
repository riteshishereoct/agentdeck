import Foundation
@testable import AgentDeckCore

enum Make {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    static func event(_ kind: EventKind, session: String = "s1", agent: String? = nil, agentType: String? = nil,
                      tool: String? = nil, toolUseId: String? = nil, preview: String? = nil, text: String? = nil,
                      notificationType: String? = nil, model: String? = nil, at: Date = t0, pid: Int32? = nil,
                      host: String? = nil, cwd: String? = "/Users/me/proj") -> AgentEvent {
        AgentEvent(sessionId: session, agentId: agent, agentType: agentType, kind: kind, tool: tool, toolUseId: toolUseId,
                   inputPreview: preview, text: text, notificationType: notificationType, model: model, ts: at,
                   pid: pid, host: host, cwd: cwd)
    }
    static func request(_ id: String = "r1", session: String = "s1", kind: RequestKind = .permission, tool: String = "Bash",
                        risk: RiskLevel = .low, channel: Channel = .race, status: RequestStatus = .pending,
                        personOnly: Bool = false, suggestions: [JSONValue] = [], at: Date = t0) -> Request {
        Request(id: id, sessionId: session, kind: kind, hook: .permissionRequest, tool: tool, preview: "Bash: npm test",
                fullInput: .object(["command": .string("npm test")]), risk: Risk(level: risk, reason: "test"),
                suggestions: suggestions, personOnly: personOnly, channel: channel, createdAt: at, status: status)
    }
}
