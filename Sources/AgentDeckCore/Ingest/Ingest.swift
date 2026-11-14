import Foundation

public enum Ingest {
    public static let previewLimit = 2048

    /// Mask first, then cut to `previewLimit` UTF-8 bytes on a Character boundary, so a token straddling the cut never leaks a prefix.
    public static func preview(_ s: String) -> String {
        let masked = Masking.mask(s)
        if masked.utf8.count <= previewLimit { return masked }
        var bytes = 0
        var end = masked.startIndex
        for i in masked.indices {
            let n = masked[i].utf8.count
            if bytes + n > previewLimit { break }
            bytes += n
            end = masked.index(after: i)
        }
        return String(masked[..<end])
    }

    public static func event(_ hook: HookKind, _ input: HookInput, meta: HookMeta, now: Date) -> AgentEvent {
        let text: String?
        switch hook {
        case .userPromptSubmit: text = input.prompt
        case .stop, .subagentStop: text = input.lastAssistantMessage
        case .notification: text = input.message
        default: text = nil
        }
        let inputPreview = input.toolName.map { preview(StepLabel.activity(tool: $0, input: input.toolInput ?? .null)) }
        return AgentEvent(sessionId: input.sessionId, agentId: input.agentId, agentType: input.agentType, kind: .hook(hook),
                          tool: input.toolName, toolUseId: input.toolUseId, inputPreview: inputPreview, text: text,
                          notificationType: input.notificationType, permissionMode: input.permissionMode, ts: now,
                          pid: meta.pid, host: meta.host, entrypoint: meta.entrypoint, cwd: input.cwd,
                          transcriptPath: input.transcriptPath)
    }
}
