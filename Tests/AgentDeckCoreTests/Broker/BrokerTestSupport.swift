import Foundation
import XCTest
@testable import AgentDeckCore

func json(_ d: Data) -> NSDictionary { try! JSONSerialization.jsonObject(with: d) as! NSDictionary }
func envelope(_ name: String) -> NSDictionary { json(Fixture.data("envelopes/\(name).json")) }
func jv(_ any: Any) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: any, options: .fragmentsAllowed))
}
func makeRequest(hook: HookKind = .permissionRequest, kind: RequestKind = .permission, tool: String = "Bash",
                 input: Any = ["command": "ls"], suggestions: [Any] = [], channel: Channel = .race) -> Request {
    Request(id: UUID().uuidString, sessionId: "s1", agentId: nil, kind: kind, hook: hook, tool: tool, toolUseId: nil,
            preview: tool, fullInput: jv(input), risk: Risk(level: .low, reason: "test"), suggestions: suggestions.map(jv),
            personOnly: false, channel: channel, createdAt: Date(timeIntervalSince1970: 1_800_000_000), status: .pending)
}

let cursor = "com.todesktop.230313mzl4w4u92"
let ui = HookMeta(pid: nil, host: cursor, entrypoint: "claude-vscode")

func call(_ tool: String, _ input: [String: Any], id: String? = nil, mode: String = "default", agent: String? = nil,
          session: String = "s1", extra: [String: Any] = [:]) -> HookInput {
    var f: [String: Any] = ["session_id": session, "cwd": "/p", "tool_name": tool, "tool_input": input, "permission_mode": mode]
    if let id { f["tool_use_id"] = id }
    if let agent { f["agent_id"] = agent }
    f.merge(extra) { $1 }
    return try! HookInput.decode(JSONSerialization.data(withJSONObject: f))
}
func bash(_ c: String, id: String? = nil, mode: String = "default", agent: String? = nil, extra: [String: Any] = [:]) -> HookInput {
    call("Bash", ["command": c], id: id, mode: mode, agent: agent, extra: extra)
}
final class FakeWaiter: HoldWaiter {
    private(set) var bodies: [Data?] = []
    func finish(_ body: Data?) { bodies.append(body) }
}
final class Recorder { var events: [AgentEvent] = []; var rules = SettingsRules(allow: [], deny: []) }
final class Harness {
    let clock: FakeClock, rec: Recorder, broker: DecisionBroker
    init(_ channels: [ToolCategory: Channel] = [:], settings: AppSettings = AppSettings()) {
        var m = CapabilityMatrix.fallback                       // every category .notify
        for (k, v) in channels { m.channels[k] = v }
        let clock = FakeClock(), rec = Recorder()
        self.clock = clock; self.rec = rec
        broker = DecisionBroker(clock: clock, matrix: m, settings: settings, rules: { _ in rec.rules }, emit: { rec.events.append($0) })
    }
    func away()    { broker.update(presence: PresenceSnapshot(frontmostBundleId: "com.google.Chrome", idleSeconds: 0, at: clock.now())) }
    func present() { broker.update(presence: PresenceSnapshot(frontmostBundleId: cursor, idleSeconds: 0, at: clock.now())) }
    func tick(_ s: TimeInterval = 0) { clock.advance(s); broker.tick(now: clock.now()) }
    var statuses: [RequestStatus] { rec.events.compactMap { if case .requestUpdated(_, let s) = $0.kind { return s }; return nil } }
    var held: [Request] { rec.events.compactMap { if case .requestHeld(let r) = $0.kind { return r }; return nil } }
    func hold(_ v: GateVerb, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard case .hold(let id) = v else { XCTFail("expected HOLD, got \(v)", file: file, line: line); return "" }
        return id
    }
    func holdAttached(_ i: HookInput, gate: Bool = false) -> (String, FakeWaiter) {
        let id = hold(gate ? broker.gate(i, meta: ui) : broker.decide(i, meta: ui)), w = FakeWaiter()
        XCTAssertTrue(broker.attach(id: id, waiter: w)); return (id, w)
    }
    func ev(_ kind: EventKind, session: String = "s1", id: String? = nil, agent: String? = nil,
            notification: String? = nil, host: String? = cursor) -> AgentEvent {
        AgentEvent(sessionId: session, agentId: agent, kind: kind, toolUseId: id, notificationType: notification,
                   ts: clock.now(), host: host, entrypoint: "claude-vscode")
    }
}
