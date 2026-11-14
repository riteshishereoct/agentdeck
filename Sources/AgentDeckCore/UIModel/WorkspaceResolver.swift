import Foundation

/// A Cursor multi-root workspace: its .code-workspace file, its absolute folders, and when it was last used.
public struct WorkspaceCandidate: Equatable {
    public let workspaceFilePath: String
    public let folders: [String]
    public let lastUsed: Date
    public init(workspaceFilePath: String, folders: [String], lastUsed: Date) {
        self.workspaceFilePath = workspaceFilePath; self.folders = folders; self.lastUsed = lastUsed
    }
}

public enum WorkspaceResolver {
    /// The .code-workspace whose folders contain `root` exactly (standardized, no prefix matches); newest wins ties.
    public static func target(forRoot root: String, candidates: [WorkspaceCandidate]) -> String? {
        let r = URL(fileURLWithPath: root).standardizedFileURL.path
        return candidates
            .filter { $0.folders.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == r } }
            .max { $0.lastUsed < $1.lastUsed }?.workspaceFilePath
    }

    /// Strips // and /* */ comments (outside strings) and trailing commas so JSONSerialization can parse JSONC.
    public static func stripJSONC(_ text: String) -> String {
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0, inString = false
        while i < c.count {
            let ch = c[i]
            if inString {
                out.append(ch)
                if ch == "\\", i + 1 < c.count { out.append(c[i + 1]); i += 1 } else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true; out.append(ch)
            } else if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
                continue
            } else if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2
                continue
            } else if ch == "," {
                var j = i + 1
                while j < c.count, c[j].properties.isWhitespace { j += 1 }
                if j < c.count, c[j] == "}" || c[j] == "]" { i += 1; continue }
                out.append(ch)
            } else { out.append(ch) }
            i += 1
        }
        return String(out)
    }

    /// Parses a .code-workspace body into absolute folder paths (relative entries resolve against `baseDir`). nil on parse failure.
    public static func folders(inWorkspaceFile text: String, baseDir: String) -> [String]? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(stripJSONC(text).utf8)) as? [String: Any],
              let list = obj["folders"] as? [[String: Any]] else { return nil }
        return list.compactMap { $0["path"] as? String }.map {
            URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: baseDir, isDirectory: true)).standardizedFileURL.path
        }
    }
}
