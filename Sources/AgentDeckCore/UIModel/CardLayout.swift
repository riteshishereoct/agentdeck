import Foundation

public enum CardButton: Equatable {
    case allow, deny, denyWithNote, openInCursor, approveInCursor, reviewInCursor, answerInCursor, needsApprovalOpen, dismiss
    case submitAnswer, allowAlways(rule: String, suggestion: JSONValue)
    public var title: String {
        switch self {
        case .submitAnswer: return "Submit"
        case .allowAlways(let rule, _): return "Allow always: " + rule
        case .allow: return "Allow"
        case .deny: return "Deny"
        case .denyWithNote: return "Deny + note…"
        case .openInCursor: return "Open in Cursor ↗"
        case .approveInCursor: return "Approve in Cursor ↗"
        case .reviewInCursor: return "Review in Cursor ↗"
        case .answerInCursor: return "Answer in Cursor ↗"
        case .needsApprovalOpen: return "needs approval · Open ↗"
        case .dismiss: return "Dismiss"
        }
    }
}

public enum CardLayout {
    public static func buttons(for r: Request) -> [CardButton] {
        if r.kind == .planReview { return [.reviewInCursor, .dismiss] }
        if r.kind == .question {
            if r.channel == .gate, r.hook == .preToolUse, !r.personOnly, !QuestionForm.parse(r.fullInput).isEmpty { return [.submitAnswer, .openInCursor] }
            return [.answerInCursor, .dismiss]
        }
        if r.channel == .notify { return [.needsApprovalOpen, .dismiss] }
        if r.personOnly { return [.deny, .approveInCursor] }
        let always: [CardButton] = r.hook == .permissionRequest && r.channel == .race
            ? r.suggestions.filter(grantsAllow).map { .allowAlways(rule: Envelopes.ruleText(for: $0), suggestion: $0) } : []
        return [.allow] + always + [.deny, .denyWithNote, .openInCursor]
    }

    /// Only suggestions that add permission belong behind "Allow always"; deny/ask rules and removals never do.
    static func grantsAllow(_ s: JSONValue) -> Bool {
        guard ["addRules", "replaceRules", "addDirectories", "setMode"].contains(s["type"]?.stringValue ?? "") else { return false }
        return s["behavior"].map { $0 == .string("allow") } ?? true
    }

    /// Allow (and Allow always) must be held, never clicked or hotkeyed: high risk, or a detail the person cannot see whole on the card.
    public static func allowNeedsHold(_ r: Request, context: ConsentContext? = nil) -> Bool {
        r.risk.level == .high || (context ?? ConsentContext.make(r, session: nil)).requiresHold
    }
}

public enum CardFormat {
    public static func displayTool(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        let parts = tool.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? parts[0] + "." + parts.dropFirst().joined(separator: "__") : tool
    }

    /// Previews usually already start with the tool ("Bash: x", "github.create_issue"): never print it twice.
    public static func headline(_ r: Request) -> String {
        r.preview.hasPrefix(displayTool(r.tool)) ? r.preview : "\(displayTool(r.tool))  \(r.preview)"
    }

    public static func risk(_ r: Risk) -> String { "\(r.level.rawValue.uppercased()) · \(r.reason)" }

    /// Replacement excerpt from the hook payload only; never opens the file being edited.
    /// Removed and added lines each get `maxLines`; anything cut is marked in the text and reported as `omitted`.
    public static func diffPreview(tool: String, input: JSONValue, maxLines: Int = 6) -> (text: String, omitted: Bool)? {
        let edits: [JSONValue]
        if tool == "MultiEdit", case .array(let values)? = input["edits"] { edits = values }
        else if tool == "Edit" || tool == "Write" { edits = [input] }
        else { return nil }
        var lines: [String] = [], left = ["− ": maxLines, "+ ": maxLines], omitted = false
        for (i, edit) in edits.enumerated() {
            if left.values.allSatisfy({ $0 <= 0 }) {
                lines.append("… \(edits.count - i) more edit\(edits.count - i == 1 ? "" : "s") not shown"); omitted = true; break
            }
            for (key, prefix) in [("old_string", "− "), (tool == "Write" ? "content" : "new_string", "+ ")] {
                guard let text = edit[key]?.stringValue, !text.isEmpty else { continue }
                let all = Masking.mask(text).components(separatedBy: "\n"), shown = all.prefix(max(0, left[prefix]!))
                lines += shown.map { prefix + $0 }
                left[prefix]! -= shown.count
                let rest = all.count - shown.count
                if rest > 0 { lines.append("\(prefix)… \(rest) more line\(rest == 1 ? "" : "s") not shown"); omitted = true }
            }
        }
        return lines.isEmpty ? nil : (lines.joined(separator: "\n"), omitted)
    }
}
