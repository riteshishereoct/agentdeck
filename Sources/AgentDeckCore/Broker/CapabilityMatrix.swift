import Foundation

public enum ToolCategory: String, CaseIterable, Sendable { case Bash, EditWrite, Web, MCP, Question, ExitPlanMode, Other }

public struct CapabilityMatrix: Equatable, Sendable {
    public static let defaultDeepLink = "cursor://anthropic.claude-code/open?session={session}"

    public var channels: [ToolCategory: Channel]
    public var deepLinkTemplate: String

    public init(channels: [ToolCategory: Channel], deepLinkTemplate: String) {
        self.channels = channels
        self.deepLinkTemplate = deepLinkTemplate
    }

    public static let fallback = CapabilityMatrix(
        channels: Dictionary(uniqueKeysWithValues: ToolCategory.allCases.map { ($0, Channel.notify) }),
        deepLinkTemplate: defaultDeepLink)

    private static func allowed(_ c: ToolCategory) -> Set<Int> {
        switch c {
        case .Question: return [2, 3]
        case .ExitPlanMode: return [3]
        default: return [1, 2, 3]
        }
    }

    /// An integer-valued, non-boolean JSON number, else nil.
    private static func integer(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        guard n.doubleValue == Double(n.intValue) else { return nil }
        return n.intValue
    }

    public static func load(from url: URL) -> CapabilityMatrix {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              integer(root["version"]) == 1 else { return fallback }
        let cats = root["categories"] as? [String: Any] ?? [:]
        var channels: [ToolCategory: Channel] = [:]
        for c in ToolCategory.allCases {
            if let n = integer(cats[c.rawValue]), allowed(c).contains(n), let ch = Channel(rawValue: n) {
                channels[c] = ch
            } else {
                channels[c] = .notify
            }
        }
        var link = defaultDeepLink
        if let s = root["deepLink"] as? String, s.contains("{session}") { link = s }
        return CapabilityMatrix(channels: channels, deepLinkTemplate: link)
    }

    public static func category(forTool tool: String) -> ToolCategory {
        switch tool {
        case "Bash": return .Bash
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .EditWrite
        case "WebFetch", "WebSearch": return .Web
        case "AskUserQuestion": return .Question
        case "ExitPlanMode": return .ExitPlanMode
        default: return tool.hasPrefix("mcp__") ? .MCP : .Other
        }
    }

    public func channel(forTool tool: String) -> Channel {
        channels[Self.category(forTool: tool)] ?? .notify
    }

    public func deepLink(sessionId: String) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let enc = sessionId.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return URL(string: deepLinkTemplate.replacingOccurrences(of: "{session}", with: enc))
            ?? URL(string: "cursor://anthropic.claude-code/open")!
    }
}
