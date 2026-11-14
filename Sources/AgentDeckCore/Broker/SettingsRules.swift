import Foundation

public struct SettingsRules: Equatable, Sendable {
    public var allow: [String]
    public var deny: [String]
    public init(allow: [String] = [], deny: [String] = []) { self.allow = allow; self.deny = deny }

    public static func load(home: URL, cwd: String) -> SettingsRules {
        let cwdURL = URL(fileURLWithPath: cwd.isEmpty ? "/" : cwd)
        let files = [home.appendingPathComponent(".claude/settings.json"),
                     cwdURL.appendingPathComponent(".claude/settings.json"),
                     cwdURL.appendingPathComponent(".claude/settings.local.json")]
        var r = SettingsRules()
        for f in files {
            guard let d = try? Data(contentsOf: f),
                  let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let perms = root["permissions"] as? [String: Any] else { continue }
            r.allow += (perms["allow"] as? [Any] ?? []).compactMap { $0 as? String }
            r.deny += (perms["deny"] as? [Any] ?? []).compactMap { $0 as? String }
        }
        return r
    }

    private static func name(_ rule: String) -> String {
        rule.firstIndex(of: "(").map { String(rule[..<$0]) } ?? rule
    }

    public func mayDeny(tool: String, input: JSONValue) -> Bool {
        deny.contains { r in
            let n = Self.name(r)
            return n == tool || (n.hasPrefix("mcp__") && tool.hasPrefix(n + "__"))
        }
    }

    public func simplyAllows(tool: String, input: JSONValue) -> Bool {
        allow.contains { r in
            if r == tool { return true }
            guard tool == "Bash", r.hasPrefix("Bash("), r.hasSuffix(":*)"),
                  let cmd = input["command"]?.stringValue else { return false }
            let p = String(r.dropFirst(5).dropLast(3))
            if cmd.contains(where: { ";|&`$<>\n".contains($0) }) { return false }
            return cmd == p || cmd.hasPrefix(p + " ")
        }
    }
}
