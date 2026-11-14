import Foundation

public enum Envelopes {
    private static func denyText(_ note: String?) -> String {
        let n = String((note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        return n.isEmpty ? "Denied in AgentDeck" : "Denied in AgentDeck: " + n
    }

    public static func data(for request: Request, decision: Decision) throws -> Data {
        let out: JSONValue
        switch request.hook {
        case .permissionRequest:
            var d: [String: JSONValue]
            switch decision {
            case .allow: d = ["behavior": .string("allow")]
            case .deny(let note): d = ["behavior": .string("deny"), "message": .string(denyText(note))]
            case .allowAlways(let s):
                guard request.suggestions.contains(s) else { throw DropReason.notApplicable }
                d = ["behavior": .string("allow"), "updatedPermissions": .array([s])]
            case .answer: throw DropReason.notApplicable
            }
            out = .object(["hookEventName": .string("PermissionRequest"), "decision": .object(d)])
        case .preToolUse:
            var o: [String: JSONValue] = ["hookEventName": .string("PreToolUse")]
            switch decision {
            case .allow:
                o["permissionDecision"] = .string("allow"); o["permissionDecisionReason"] = .string("Approved in AgentDeck")
            case .deny(let note):
                o["permissionDecision"] = .string("deny"); o["permissionDecisionReason"] = .string(denyText(note))
            case .answer(let a):
                guard request.kind == .question, case .object(var input) = request.fullInput, !a.isEmpty,
                      case .array(let qs)? = input["questions"] else { throw DropReason.notApplicable }
                let asked = Set(qs.compactMap { $0["question"]?.stringValue })
                guard a.keys.allSatisfy(asked.contains) else { throw DropReason.notApplicable }
                input["answers"] = .object(a.mapValues { .string($0) })
                o["permissionDecision"] = .string("allow"); o["permissionDecisionReason"] = .string("Answered in AgentDeck")
                o["updatedInput"] = .object(input)
            case .allowAlways: throw DropReason.notApplicable
            }
            out = .object(o)
        default:
            throw DropReason.notApplicable
        }
        return try JSONValue.object(["hookSpecificOutput": out]).compactData()
    }

    /// Human text for an "Allow always" suggestion, including its exact scope (G-CONSENT). Unknown shapes fall back to raw JSON.
    /// Masked for display only: the envelope always sends the suggestion verbatim.
    public static func ruleText(for suggestion: JSONValue) -> String { Masking.mask(rawRuleText(suggestion)) }

    private static func rawRuleText(_ suggestion: JSONValue) -> String {
        let scopes = ["session": "for this session", "localSettings": "in this project (your local settings)",
                      "projectSettings": "in this project (shared settings)", "userSettings": "for all projects"]
        let dest = suggestion["destination"]?.stringValue.map { scopes[$0] ?? $0 }
        func scoped(_ t: String) -> String { dest.map { "\(t) · \($0)" } ?? t }
        let behavior = suggestion["behavior"]?.stringValue.map { $0 == "allow" ? "" : "\($0) " } ?? ""   // "deny "/"ask " is never hidden
        let type = suggestion["type"]?.stringValue
        switch type {
        case "addRules", "replaceRules", "removeRules":
            if case .array(let rules)? = suggestion["rules"], !rules.isEmpty {
                let parts = rules.map { r -> String? in
                    let c = r["ruleContent"]?.stringValue
                    guard let t = r["toolName"]?.stringValue else { return c.map { "(tool not given)(\($0))" } }
                    return c.map { "\(t)(\($0))" } ?? t
                }
                if parts.allSatisfy({ $0 != nil }) {
                    let list = parts.compactMap { $0 }.joined(separator: ", ")
                    let verb = type == "replaceRules" ? "replace your \(behavior.isEmpty ? "allow " : behavior)rules with " : type == "removeRules" ? "remove \(behavior)rule " : behavior
                    return scoped(verb + list)
                }
            }
        case "addDirectories", "removeDirectories":
            if case .array(let dirs)? = suggestion["directories"] {
                let ds = dirs.compactMap { $0.stringValue }
                if !ds.isEmpty, ds.count == dirs.count {
                    return scoped((type == "addDirectories" ? "access to " : "remove access to ") + ds.joined(separator: ", "))
                }
            }
        case "setMode":
            let names = ["acceptEdits": "accept-edits mode (file edits without asking)", "bypassPermissions": "bypass-permissions mode (no prompts at all)",
                         "plan": "plan mode", "default": "default mode"]
            if let m = suggestion["mode"]?.stringValue { return scoped("switch to " + (names[m] ?? "\(m) mode")) }
        default: break
        }
        return String(decoding: (try? suggestion.compactData()) ?? Data(), as: UTF8.self)
    }
}
