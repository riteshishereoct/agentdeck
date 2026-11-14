import Foundation

public enum HookInputError: Error, Equatable { case notAnObject, missingSessionId }

public struct HookInput: Equatable, Sendable {
    public var raw: [String: JSONValue]
    public var sessionId: String
    public var transcriptPath: String?
    public var cwd: String?
    public var permissionMode: String?
    public var hookEventName: String?
    public var toolName: String?
    public var toolInput: JSONValue?
    public var toolUseId: String?
    public var agentId: String?
    public var agentType: String?
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var notificationType: String?
    public var message: String?
    public var permissionSuggestions: [JSONValue]
    public var mcpServer: String?
    public var personOnly: Bool

    public init(raw: [String: JSONValue] = [:], sessionId: String, transcriptPath: String? = nil, cwd: String? = nil,
                permissionMode: String? = nil, hookEventName: String? = nil, toolName: String? = nil,
                toolInput: JSONValue? = nil, toolUseId: String? = nil, agentId: String? = nil, agentType: String? = nil,
                prompt: String? = nil, lastAssistantMessage: String? = nil, notificationType: String? = nil,
                message: String? = nil, permissionSuggestions: [JSONValue] = [], mcpServer: String? = nil,
                personOnly: Bool = false) {
        self.raw = raw; self.sessionId = sessionId; self.transcriptPath = transcriptPath; self.cwd = cwd
        self.permissionMode = permissionMode; self.hookEventName = hookEventName; self.toolName = toolName
        self.toolInput = toolInput; self.toolUseId = toolUseId; self.agentId = agentId; self.agentType = agentType
        self.prompt = prompt; self.lastAssistantMessage = lastAssistantMessage; self.notificationType = notificationType
        self.message = message; self.permissionSuggestions = permissionSuggestions; self.mcpServer = mcpServer
        self.personOnly = personOnly
    }

    public static func decode(_ data: Data) throws -> HookInput {
        guard case .object(let raw) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw HookInputError.notAnObject
        }
        guard let sid = raw["session_id"]?.stringValue else { throw HookInputError.missingSessionId }
        func s(_ k: String) -> String? { raw[k]?.stringValue }
        var suggestions: [JSONValue] = []
        if case .array(let a)? = raw["permission_suggestions"] { suggestions = a }
        return HookInput(raw: raw, sessionId: sid, transcriptPath: s("transcript_path"), cwd: s("cwd"),
                         permissionMode: s("permission_mode"), hookEventName: s("hook_event_name"),
                         toolName: s("tool_name"), toolInput: raw["tool_input"], toolUseId: s("tool_use_id"),
                         agentId: s("agent_id"), agentType: s("agent_type"), prompt: s("prompt"),
                         lastAssistantMessage: s("last_assistant_message"), notificationType: s("notification_type"),
                         message: s("message"), permissionSuggestions: suggestions, mcpServer: s("mcp_server"),
                         personOnly: raw["person_only"] == .bool(true))
    }
}
