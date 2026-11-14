import Foundation
@testable import AgentDeckCore

enum UI {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func request(_ id: String, session: String = "s1", tool: String = "Bash", kind: RequestKind = .permission,
                        hook: HookKind = .permissionRequest, risk: RiskLevel = .low, channel: Channel = .race,
                        personOnly: Bool = false, suggestions: [JSONValue] = [], preview: String = "npm test",
                        input: JSONValue = .object(["command": .string("npm test")]),
                        at: Date = t0, status: RequestStatus = .pending) -> Request {
        Request(id: id, sessionId: session, agentId: nil, kind: kind, hook: hook, tool: tool, toolUseId: nil,
                preview: preview, fullInput: input, risk: Risk(level: risk, reason: "r"), suggestions: suggestions,
                personOnly: personOnly, channel: channel, createdAt: at, status: status)
    }
    static func session(_ id: String = "s1", project: String = "proj", state: SessionState = .working, title: String? = nil,
                        goal: String? = nil, model: String? = nil, step: Step? = nil, stepCount: Int = 0,
                        progress: TaskProgress? = nil, activity: [Int] = [], summary: String? = nil,
                        degraded: Bool = false, subagents: [Agent] = [], pending: [Request] = [],
                        host: String? = "com.todesktop.230313mzl4w4u92", lastEventAt: Date = t0) -> Session {
        Session(id: id, project: project, cwd: "/tmp/\(project)", transcriptPath: nil, pid: nil, host: host, entrypoint: nil,
                title: title, goal: goal, latestAsk: nil, model: model, state: state, currentStep: step, stepCount: stepCount,
                failureStreak: 0, progress: progress, activity: activity, summary: summary, hooksDegraded: degraded,
                subagents: subagents, pending: pending, startedAt: t0, lastEventAt: lastEventAt, endedAt: nil)
    }
}
