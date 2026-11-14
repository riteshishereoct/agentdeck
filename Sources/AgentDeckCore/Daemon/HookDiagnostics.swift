import Foundation
import Darwin

/// Read-only checks behind hook health (docs/hook-health.md). None of them writes, prints or logs settings content.
enum HookDiagnostics {
    static let events = ["PermissionRequest", "PreToolUse", "PostToolUse", "PostToolUseFailure", "UserPromptSubmit", "PermissionDenied",
                         "Stop", "SubagentStart", "SubagentStop", "Notification", "SessionStart", "SessionEnd"]
    static let marker = "/.agentdeck/bin/adeck-hook"   // installer/adeck_settings.py MARKER

    static func hookScript(home: URL) -> URL { home.appendingPathComponent(".agentdeck/bin/adeck-hook") }
    static func settings(home: URL) -> URL { home.appendingPathComponent(".claude/settings.json") }

    /// Our own listener accepts a connection (connect only; the daemon never reads from it).
    static func socketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: a.sun_path) else { return false }
        withUnsafeMutableBytes(of: &a.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b } }
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    /// Every one of the 12 events has an AgentDeck command entry.
    static func registered(settings url: URL) -> Bool {
        guard let d = try? Data(contentsOf: url), let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev in
            (hooks[ev] as? [Any] ?? []).contains { group in
                ((group as? [String: Any])?["hooks"] as? [Any] ?? []).contains { (($0 as? [String: Any])?["command"] as? String)?.contains(marker) == true }
            }
        }
    }

    /// nil = installed, executable and (when the bundled copy is known) byte-equal to it.
    static func scriptProblem(at url: URL, bundled: URL?) -> HookHealth.Cause? {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return .hookScriptMissing }
        if let bundled, let want = try? Data(contentsOf: bundled), (try? Data(contentsOf: url)) != want { return .hookScriptOutdated }
        return nil
    }

    /// "…/anthropic.claude-code-2.1.323-darwin-arm64/resources/native-binary/claude" → "2.1.323"; nil for a CLI install.
    static func version(inPath path: String) -> String? {
        guard let r = path.range(of: #"claude-code-[0-9]+(\.[0-9]+)+"#, options: .regularExpression) else { return nil }
        return String(path[r].dropFirst("claude-code-".count))
    }

    static func runningVersion(pid: Int32?) -> String? {
        guard let pid, pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return version(inPath: String(cString: buf))
    }

    static func recordedVersion(capabilities url: URL) -> String? {
        guard let d = try? Data(contentsOf: url), let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return root["extensionVersion"] as? String
    }
}
