import Foundation

/// Running TaskCreate/TaskUpdate count for one session (the transcript only carries deltas). Shapes are unverified until Phase 0.
public struct TaskTally: Equatable, Sendable {
    var created = 0
    var completed: Set<String> = []
    public init() {}
}

public enum TranscriptParser {
    private static let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let iso = ISO8601DateFormatter()

    public static func events(fromLine line: Data, sessionId: String, now: Date) -> [AgentEvent] {
        var tally = TaskTally()
        return events(fromLine: line, sessionId: sessionId, now: now, tally: &tally)
    }

    /// Tolerant by design: any malformed, non-object or unknown line yields `[]`.
    public static func events(fromLine line: Data, sessionId: String, now: Date, tally: inout TaskTally) -> [AgentEvent] {
        guard !line.isEmpty, let json = try? JSONDecoder().decode(JSONValue.self, from: line), case .object = json else { return [] }
        let ts = json["timestamp"]?.stringValue.flatMap { isoFrac.date(from: $0) ?? iso.date(from: $0) } ?? now
        func event(_ kind: EventKind, tool: String? = nil, toolUseId: String? = nil, text: String? = nil, model: String? = nil) -> AgentEvent {
            AgentEvent(sessionId: sessionId, kind: kind, tool: tool, toolUseId: toolUseId, text: text, model: model, ts: ts)
        }
        let blocks: [JSONValue]
        if case .array(let a)? = json["message"]?["content"] { blocks = a } else { blocks = [] }

        switch json["type"]?.stringValue {
        case "assistant":
            var out: [AgentEvent] = []
            let model = json["message"]?["model"]?.stringValue
            let texts = blocks.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }
            let text = texts.isEmpty ? nil : Ingest.preview(texts.joined(separator: "\n"))
            if model != nil || text != nil { out.append(event(.transcriptAssistant, text: text, model: model)) }
            for b in blocks where b["type"]?.stringValue == "tool_use" {
                let name = b["name"]?.stringValue
                out.append(event(.transcriptToolUse, tool: name, toolUseId: b["id"]?.stringValue))
                switch name {
                case "TodoWrite":
                    if case .array(let todos)? = b["input"]?["todos"] {
                        out.append(event(.transcriptTasks(TaskProgress(done: todos.filter { $0["status"]?.stringValue == "completed" }.count, total: todos.count))))
                    }
                case "TaskCreate":
                    tally.created += 1; out.append(event(.transcriptTasks(progress(tally))))
                case "TaskUpdate":
                    if b["input"]?["status"]?.stringValue == "completed", let id = b["input"]?["taskId"]?.stringValue { tally.completed.insert(id) }
                    out.append(event(.transcriptTasks(progress(tally))))
                default: break
                }
            }
            return out
        case "user":
            return blocks.filter { $0["type"]?.stringValue == "tool_result" }.map {
                var isError = false
                if case .bool(true)? = $0["is_error"] { isError = true }
                return event(.transcriptToolResult(isError: isError), toolUseId: $0["tool_use_id"]?.stringValue)
            }
        case "summary":
            guard let s = json["summary"]?.stringValue else { return [] }
            return [event(.transcriptTitle, text: Ingest.preview(s))]
        case "ai-title":   // Claude Code rewrites this line as the session evolves; the reducer keeps the latest
            guard let t = json["aiTitle"]?.stringValue, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [event(.transcriptTitle, text: Ingest.preview(t))]
        default:
            return []
        }
    }

    private static func progress(_ t: TaskTally) -> TaskProgress { TaskProgress(done: t.completed.count, total: max(t.created, t.completed.count)) }
}
