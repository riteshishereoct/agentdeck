import Foundation

public enum StepLabel {
    /// Row "Now:" text: the agent's own short `description` for Bash/Agent when present, else `label`.
    /// Never used for consent cards, which must show the real command (`label`).
    public static func activity(tool: String, input: JSONValue) -> String {
        if ["Bash", "Task", "Agent"].contains(tool),
           let d = input["description"]?.stringValue?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces), !d.isEmpty {
            return tool == "Bash" ? d : "Agent: \(d)"
        }
        return label(tool: tool, input: input)
    }

    public static func label(tool: String, input: JSONValue) -> String {
        func str(_ k: String) -> String? { input[k]?.stringValue }
        func base(_ k: String) -> String? { str(k).map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } }
        func join(_ rest: String?) -> String { rest.map { "\(tool) \($0)" } ?? tool }
        switch tool {
        case "Bash":
            let first = str("command")?.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            return first.map { "Bash: \($0)" } ?? "Bash"
        case "Edit":
            guard let f = base("file_path") else { return tool }
            if str("new_string") == nil && str("old_string") == nil { return "Edit \(f)" }
            return "Edit \(f) +\(lineCount(str("new_string"))) −\(lineCount(str("old_string")))"
        case "Write":
            guard let f = base("file_path") else { return tool }
            return str("content").map { "Write \(f) +\(lineCount($0))" } ?? "Write \(f)"
        case "MultiEdit":
            guard let f = base("file_path") else { return tool }
            guard case .array(let edits)? = input["edits"] else { return "MultiEdit \(f)" }
            let add = edits.reduce(0) { $0 + lineCount($1["new_string"]?.stringValue) }
            let del = edits.reduce(0) { $0 + lineCount($1["old_string"]?.stringValue) }
            return "MultiEdit \(f) +\(add) −\(del)"
        case "NotebookEdit": return join(base("notebook_path"))
        case "Read": return join(base("file_path"))
        case "Grep", "Glob": return join(str("pattern"))
        case "WebFetch": return join(str("url"))
        case "WebSearch": return join(str("query"))
        case "Task", "Agent": return str("subagent_type").map { "Agent: \($0)" } ?? "Agent"
        case "AskUserQuestion":
            if case .array(let qs)? = input["questions"], let q = qs.first?["question"]?.stringValue { return "Question: \(q)" }
            return tool
        case "ExitPlanMode": return "Plan review"
        default:
            guard tool.hasPrefix("mcp__") else { return tool }
            let rest = String(tool.dropFirst(5))
            if let r = rest.range(of: "__") { return "\(rest[..<r.lowerBound]).\(rest[r.upperBound...])" }
            return rest
        }
    }

    /// 0 for nil/empty, else `\n`-separated lines with one trailing newline ignored.
    private static func lineCount(_ s: String?) -> Int {
        guard var s, !s.isEmpty else { return 0 }
        if s.hasSuffix("\n") { s.removeLast() }
        return s.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}
