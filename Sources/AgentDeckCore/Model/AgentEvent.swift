import Foundation

public struct HookMeta: Equatable, Sendable {
    public var pid: Int32?
    public var host: String?
    public var entrypoint: String?
    public init(pid: Int32? = nil, host: String? = nil, entrypoint: String? = nil) {
        self.pid = pid; self.host = host; self.entrypoint = entrypoint
    }
}

public enum EventKind: Equatable, Sendable {
    case hook(HookKind)
    case transcriptToolUse
    case transcriptToolResult(isError: Bool)
    case transcriptAssistant
    case transcriptTitle
    case transcriptTasks(TaskProgress)
    case requestHeld(Request)
    case requestUpdated(id: String, status: RequestStatus)
    case pidGone
    case tick
}

public struct AgentEvent: Equatable, Sendable {
    public var sessionId: String
    public var agentId: String?
    public var agentType: String?
    public var kind: EventKind
    public var tool: String?
    public var toolUseId: String?
    public var inputPreview: String?
    public var text: String?
    public var notificationType: String?
    public var permissionMode: String?
    public var model: String?
    public var ts: Date
    public var pid: Int32?
    public var host: String?
    public var entrypoint: String?
    public var cwd: String?
    public var transcriptPath: String?

    public init(sessionId: String, agentId: String? = nil, agentType: String? = nil, kind: EventKind, tool: String? = nil,
                toolUseId: String? = nil, inputPreview: String? = nil, text: String? = nil, notificationType: String? = nil,
                permissionMode: String? = nil, model: String? = nil, ts: Date, pid: Int32? = nil, host: String? = nil,
                entrypoint: String? = nil, cwd: String? = nil, transcriptPath: String? = nil) {
        self.sessionId = sessionId; self.agentId = agentId; self.agentType = agentType; self.kind = kind; self.tool = tool
        self.toolUseId = toolUseId; self.inputPreview = inputPreview; self.text = text; self.notificationType = notificationType
        self.permissionMode = permissionMode; self.model = model; self.ts = ts; self.pid = pid; self.host = host
        self.entrypoint = entrypoint; self.cwd = cwd; self.transcriptPath = transcriptPath
    }
}
