import Foundation

/// G-CONSENT: everything a person needs to judge a request, shown on the card before any decision.
/// `what` and `scope` come from AgentDeck's own reading of the tool call; `reason` is the agent's own words, labelled as such.
/// `detail` is always the real (masked) command / file / input, never a description of it.
public struct ConsentContext: Equatable {
    public var task: String?        // the session's latest ask (or goal), for "what is this agent doing"
    public var what: String         // plain language, chosen by AgentDeck from the tool
    public var detailLabel: String  // "Command", "File", "URL", "Query", "Input"
    public var detail: String       // real masked content; may be long (the card scrolls it)
    public var reason: String       // "Agent's reason: …" or "Reason not provided"
    public var scope: String        // what it can touch
    public var risk: String         // "LOW · Routine action"
    public var identity: String     // "#405d83 · agentdeck-probe": never truncated, tells same-project sessions apart
    public var sessionTitle: String? // the session's own title/goal; may wrap
    public var incomplete = false   // part of the real input is not on the card (diff budget or character cap)

    /// Too long to read without scrolling the detail box; the card always shows `tail` outside the box too.
    public var overflows: Bool { detail.count > 500 || detail.split(separator: "\n", omittingEmptySubsequences: false).count > 8 }
    /// Allow must be a deliberate hold when the person may not have seen everything they approve.
    public var requiresHold: Bool { incomplete || overflows }
    /// The last lines of the detail (at most 300 characters), shown under a scrolling box so the end of a command is never unseen.
    public var tail: String {
        let t = detail.split(separator: "\n", omittingEmptySubsequences: false).suffix(3).joined(separator: "\n")
        return t.count > 300 ? "…" + t.suffix(300) : t
    }

    public static let reasonMissing = "Reason not provided"
    static let detailCap = 8000, capHead = 6000, capTail = 1500

    public static func make(_ r: Request, session: Session?) -> ConsentContext {
        let input = r.fullInput
        func str(_ k: String) -> String? { input[k]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        let cwd = session?.cwd.isEmpty == false ? session!.cwd : nil
        let tool = CardFormat.displayTool(r.tool)
        let file = str("file_path") ?? str("notebook_path")
        var what = "Use \(tool)", label = "Input", detail = pretty(input), scope = "Acts with your user permissions", omitted = false
        func diff() -> String {
            let d = CardFormat.diffPreview(tool: r.tool, input: input, maxLines: 400)
            omitted = d?.omitted ?? false
            return [file, d?.text].compactMap { $0 }.joined(separator: "\n")
        }
        guard case .object = input else {
            // Notification-only cards (e.g. permission_prompt) carry no tool input: show the notice text itself.
            return ConsentContext(task: task(session), what: "Approve or deny in Cursor", detailLabel: "Notice", detail: cap(Masking.mask(r.preview)).text,
                                  reason: reasonMissing, scope: "Decided in Cursor; AgentDeck cannot see the exact request",
                                  risk: CardFormat.risk(r.risk), identity: identity(r, session), sessionTitle: title(session))
        }
        switch r.tool {
        case "Bash":
            what = "Run a shell command"; label = "Command"; detail = str("command") ?? detail
            scope = cwd.map { "Runs in \($0) with your user permissions" } ?? "Runs with your user permissions (folder unknown)"
        case "Edit", "MultiEdit":
            what = "Edit a file"; label = "File"
            detail = diff()
            scope = file.map { "Changes only \($0)" } ?? "File not reported"
        case "Write":
            what = "Create or overwrite a file"; label = "File"
            detail = diff()
            scope = file.map { "Writes \($0) (replaces its whole contents)" } ?? "File not reported"
        case "NotebookEdit":
            what = "Edit a notebook"; label = "File"
            detail = file.map { [$0, str("new_source")].compactMap { $0 }.joined(separator: "\n") } ?? detail
            scope = file.map { "Changes only \($0)" } ?? "File not reported"
        case "WebFetch":
            what = "Fetch a web page"; label = "URL"; detail = str("url") ?? detail
            scope = str("url").flatMap { URL(string: $0)?.host }.map { "Sends a request to \($0)" } ?? "Sends a network request"
        case "WebSearch":
            what = "Search the web"; label = "Query"; detail = str("query") ?? detail; scope = "Sends the query to a search service"
        case "Task", "Agent":
            what = "Start a subagent"; label = "Task"; detail = str("prompt") ?? detail; scope = "The subagent can use tools in this session"
        case "AskUserQuestion":
            what = "Answer a question from the agent"; label = "Question"
            detail = QuestionForm.readable(input).isEmpty ? detail : QuestionForm.readable(input); scope = "Your answer is sent to this session only"
        case "ExitPlanMode":
            what = "Review the agent's plan"; label = "Plan"; detail = str("plan") ?? detail; scope = "Approving lets the agent start making changes"
        default:
            if r.tool.hasPrefix("mcp__") {
                let server = tool.components(separatedBy: ".").first ?? tool
                what = "Use the \(server) tool \(tool.dropFirst(server.count + 1))"; scope = "Acts through the \(server) MCP server"
            }
        }
        // Only the agent's own short `description` counts as its reason; nothing is inferred.
        let reason = str("description").map { "Agent's reason: " + Masking.mask($0) } ?? reasonMissing
        let capped = cap(Masking.mask(detail))
        return ConsentContext(task: task(session), what: what, detailLabel: label, detail: capped.text, reason: reason,
                              scope: Masking.mask(scope), risk: CardFormat.risk(r.risk), identity: identity(r, session), sessionTitle: title(session),
                              incomplete: omitted || capped.cut)
    }

    private static func task(_ s: Session?) -> String? { (s?.latestAsk ?? s?.goal).flatMap { SessionLabels.goal($0) } }
    private static func title(_ s: Session?) -> String? { s.flatMap { SessionLabels.goal($0.title) ?? SessionLabels.goal($0.goal) } }
    private static func identity(_ r: Request, _ s: Session?) -> String {
        s.map { RowFormat.shortId($0) + " · " + ($0.project.isEmpty ? "unknown project" : $0.project) } ?? "#" + String(r.sessionId.prefix(6))
    }

    /// Keeps the head and the real tail (where a dangerous `&& rm …` would hide), with the cut marked in between.
    private static func cap(_ s: String) -> (text: String, cut: Bool) {
        guard s.count > detailCap else { return (s, false) }
        return (String(s.prefix(capHead)) + "\n… \(s.count - capHead - capTail) characters not shown (open in Cursor to see all) …\n" + String(s.suffix(capTail)), true)
    }

    private static func pretty(_ v: JSONValue) -> String {
        guard let d = try? v.compactData(), let o = try? JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed),
              JSONSerialization.isValidJSONObject(o),   // a bare fragment would raise NSInvalidArgumentException, not throw
              let p = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return String(decoding: p, as: UTF8.self)
    }
}
