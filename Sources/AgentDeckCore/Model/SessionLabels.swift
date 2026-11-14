import Foundation

public enum SessionLabels {
    static let maxLabel = 90
    private static let wrappers = ["ide_opened_file", "ide_selection", "system-reminder", "local-command-stdout", "local-command-stderr", "command-message"]
    // A block cut off by the preview limit has no closing tag: it runs to the end (\z).
    private static func block(_ tag: String) -> String { "<\(tag)\\b[^>]*>(.*?)(</\(tag)>|\\z)" }
    private static let opts: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    private static let wrapperRE = try! NSRegularExpression(pattern: wrappers.map(block).joined(separator: "|"), options: opts)
    private static let pastedRE = try! NSRegularExpression(pattern: block("pasted_content"), options: opts)
    private static let commandRE = try! NSRegularExpression(pattern: #"<command-name>(.*?)</command-name>\s*(?:<command-args>(.*?)</command-args>)?"#, options: opts)
    private static let strayRE = try! NSRegularExpression(pattern: #"</?(?:pasted_content|command-name|command-args|command-message)\b[^>]*>|<synthetic>"#, options: opts)
    private static let sentenceRE = try! NSRegularExpression(pattern: #"(?<![0-9])[.!?](?=\s|$)|[。！？]"#)

    private static func sub(_ re: NSRegularExpression, _ s: String, _ template: String = "") -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// One readable line for a row: wrapper blocks removed, masked, whitespace collapsed, first sentence, capped at 90 on a word boundary.
    public static func goal(_ text: String?) -> String? {
        guard var t = text else { return nil }
        t = sub(wrapperRE, t)
        t = sub(commandRE, t, " $1 $2 ")   // "/x y"; the name already carries its slash in real transcripts
        let withoutPasted = sub(pastedRE, t)
        if sub(strayRE, withoutPasted).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let m = pastedRE.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) {
            t = String(t[r]).split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
        } else { t = withoutPasted }
        t = Ingest.preview(sub(strayRE, t))   // mask BEFORE any truncation
        // First non-empty line is the headline (later lines are usually pasted detail); then whitespace is collapsed.
        t = t.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }?.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression) ?? ""
        if let m = sentenceRE.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) { t = String(t[..<r.upperBound]) }
        guard !t.isEmpty else { return nil }
        guard t.count > maxLabel else { return t }
        let cut = String(t.prefix(maxLabel - 1))   // Character-based: never splits an emoji/grapheme
        let atBoundary = t[t.index(t.startIndex, offsetBy: maxLabel - 1)] == " "
        let word = atBoundary ? cut : cut.lastIndex(of: " ").map { String(cut[..<$0]) }.flatMap { $0.isEmpty ? nil : $0 } ?? cut
        return word.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Recover labels only: historical transcript entries must not replay work or change activity times.
    static func restoringContext(_ session: Session) -> Session {
        guard let path = session.transcriptPath, let file = FileHandle(forReadingAtPath: path) else { return session }
        defer { try? file.close() }
        // shortcut: only the first 1MB is searched; expand recovery if sessions carry longer startup metadata.
        guard let data = try? file.read(upToCount: 1_048_576) else { return session }
        var restored = session
        var workspace: String?
        var title: String?
        var sawGoal = false
        for line in data.split(separator: 10) {
            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            if workspace == nil, let cwd = json["cwd"]?.stringValue, !cwd.isEmpty { workspace = cwd }
            if json["type"]?.stringValue == "ai-title", let t = json["aiTitle"]?.stringValue { title = t }
            guard !sawGoal, json["type"]?.stringValue == "user", json["isMeta"] != .bool(true) else { continue }
            let content = json["message"]?["content"]
            let text: String?
            if case .array(let blocks)? = content {
                text = blocks.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            } else { text = content?.stringValue }
            guard let originalGoal = goal(text) else { continue }
            if goal(restored.goal) == nil { restored.goal = originalGoal }
            sawGoal = true
        }
        if goal(restored.title) == nil, let t = goal(title) { restored.title = t }
        if let workspace { restored.project = (workspace as NSString).lastPathComponent; if restored.workspaceRoot == nil { restored.workspaceRoot = workspace } }
        return restored
    }
}
