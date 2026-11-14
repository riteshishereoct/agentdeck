public enum HookKind: String, Codable, CaseIterable, Sendable {
    case sessionStart = "SessionStart", sessionEnd = "SessionEnd", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", permissionRequest = "PermissionRequest", permissionDenied = "PermissionDenied"
    case postToolUse = "PostToolUse", postToolUseFailure = "PostToolUseFailure", notification = "Notification"
    case stop = "Stop", subagentStart = "SubagentStart", subagentStop = "SubagentStop", preCompact = "PreCompact"
}
