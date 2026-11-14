import Foundation

public enum RiskRules {
    private struct Rule { let re: NSRegularExpression; let reason: String }
    private static func rx(_ p: String, _ reason: String) -> Rule { Rule(re: try! NSRegularExpression(pattern: p), reason: reason) }

    private static let bashHigh: [Rule] = [
        rx(#"\brm\s+(-[a-zA-Z]*(rf|fr)[a-zA-Z]*|-r\s+-f|-f\s+-r)\b"#, "Recursive force delete (rm -rf)"),
        rx(#"\bsudo\b"#, "Runs as root (sudo)"),
        rx(#"\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, "Pipes a download into a shell"),
        rx(#"\bgit\b[^;&|]*\bpush\b"#, "Pushes to a remote (git push)"),
        rx(#"\bgit\b[^;&|]*\breset\b[^;&|]*--hard"#, "Discards local work (git reset --hard)"),
        rx(#"\bnpm\s+publish\b"#, "Publishes a package (npm publish)"),
    ]
    private static let prodWord = try! NSRegularExpression(pattern: #"\b(prod|production)\b"#)
    private static let cloudTool = try! NSRegularExpression(pattern: #"\b(aws|kubectl|mongo|mongosh)\b"#)
    private static let sqlRules: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\b(DROP|DELETE|TRUNCATE)\b"#),
        try! NSRegularExpression(pattern: #"(?i)\b(drop\s+(table|database|schema|index)|delete\s+from|truncate\s+(table\s+)?\w+)"#),
    ]
    private static let bashMed: [Rule] = [
        rx(#"\b(curl|wget)\b"#, "Network request"),
        rx(#"\b(npm|pnpm|yarn)\s+(install|i|add|ci)\b"#, "Installs packages"),
        rx(#"\bpip3?\s+install\b"#, "Installs packages"),
        rx(#"\bbrew\s+install\b"#, "Installs packages"),
        rx(#"\b(gem|cargo)\s+install\b"#, "Installs packages"),
        rx(#"\bgo\s+(get|install)\b"#, "Installs packages"),
        rx(#"\bgit\b[^;&|]*\bcommit\b"#, "Creates a git commit"),
    ]
    private static let mcpWriteTokens: Set<String> = ["create", "update", "delete", "remove", "write", "send", "post", "put", "patch",
                                                     "push", "merge", "add", "set", "edit", "upload", "execute", "run", "insert", "drop"]

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    public static func classify(tool: String, input: JSONValue, cwd: String) -> Risk {
        switch tool {
        case "Bash":
            let cmd = input["command"]?.stringValue ?? ""
            for r in bashHigh where matches(r.re, cmd) { return Risk(level: .high, reason: r.reason) }
            if matches(prodWord, cmd) && matches(cloudTool, cmd) { return Risk(level: .high, reason: "Touches production infrastructure") }
            if sqlRules.contains(where: { matches($0, cmd) }) { return Risk(level: .high, reason: "Destructive SQL (DROP/DELETE/TRUNCATE)") }
            for r in bashMed where matches(r.re, cmd) { return Risk(level: .med, reason: r.reason) }
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let key = tool == "NotebookEdit" ? "notebook_path" : "file_path"
            if let p = input[key]?.stringValue, !p.isEmpty {
                let last = (p as NSString).lastPathComponent
                let comps = (p as NSString).pathComponents
                if last.hasPrefix(".env") || last.hasSuffix(".pem") || last.hasSuffix(".key") || comps.contains("jwt") {
                    return Risk(level: .high, reason: "Edits a secrets or key file")
                }
                if !cwd.isEmpty {
                    let abs = p.hasPrefix("/") ? p : (cwd as NSString).appendingPathComponent(p)
                    let std = (abs as NSString).standardizingPath, root = (cwd as NSString).standardizingPath
                    if std != root && !std.hasPrefix(root + "/") { return Risk(level: .high, reason: "Writes outside the project folder") }
                }
            }
        case "WebFetch", "WebSearch":
            return Risk(level: .med, reason: "Network request")
        default:
            if tool.hasPrefix("mcp__"), let last = tool.components(separatedBy: "__").last, isMcpWrite(last) {
                return Risk(level: .med, reason: "MCP tool that changes data")
            }
        }
        return Risk(level: .low, reason: "Routine action")
    }

    /// Split on `_`, `-`, `.` and camelCase boundaries, lower-cased.
    private static func isMcpWrite(_ name: String) -> Bool {
        var spaced = ""
        var prev: Character?
        for ch in name {
            if let p = prev, ch.isUppercase, p.isLowercase || p.isNumber { spaced.append(" ") }
            spaced.append(ch); prev = ch
        }
        let tokens = spaced.lowercased().split(whereSeparator: { "_-. ".contains($0) }).map(String.init)
        return tokens.contains { mcpWriteTokens.contains($0) }
    }
}
