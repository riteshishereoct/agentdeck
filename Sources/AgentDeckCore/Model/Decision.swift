import Foundation

public enum Decision: Equatable, Sendable {
    case allow
    case allowAlways(suggestion: JSONValue)
    case deny(note: String?)
    case answer([String: String])
}

public enum DecisionSource: Equatable, Sendable {
    case click, holdConfirmed, hotkey, notification
    /// Another approval channel (e.g. "slack") answered through `POST /v1/external/resolve`.
    case external(String)
    public var name: String { if case .external(let n) = self { return "external:" + n }; return String(describing: self) }
}

public enum ExternalResolveResult: Equatable, Sendable { case resolved, noMatch, conflict, refused(DropReason) }
public enum ExternalClaimResult: Equatable, Sendable { case claimed(String), noMatch, conflict }

public enum ResolveResult: Equatable, Sendable {
    case applied
    case dropped(DropReason)
}

public enum DropReason: String, Error, Sendable {
    case unknownOrResolved, personOnly, needsHoldConfirm, notAllowedFromSource, notApplicable
}

public enum GateVerb: Equatable, Sendable {
    case pass, decide(Data), hold(id: String)
    public var wireBody: String {
        switch self {
        case .pass: return "PASS"
        case .decide(let d): return "DECIDE " + String(decoding: d, as: UTF8.self)
        case .hold(let id): return "HOLD " + id
        }
    }
}
