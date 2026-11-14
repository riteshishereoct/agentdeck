import XCTest
@testable import AgentDeckCore

final class GateTests: XCTestCase {
    let gated: [ToolCategory: Channel] = [.Bash: .gate, .EditWrite: .gate, .Other: .gate, .Web: .notify, .MCP: .race]
    func s(_ f: (inout AppSettings) -> Void) -> AppSettings { var x = AppSettings(); f(&x); return x }

    func testGateTable() {   // protocol §6 / spec §7 pass-through rules; anything else holds on .gate
        let none = SettingsRules(allow: [], deny: []), d = AppSettings(), edit = ["file_path": "/p/a.swift"]
        let rows: [(String, HookInput, AppSettings, SettingsRules, Bool, Bool)] = [   // label, input, settings, rules, present, expect HOLD
            ("away, med risk", bash("npm install"), d, none, false, true),
            ("present", bash("npm install"), d, none, true, false),
            ("bypassPermissions", bash("npm install", mode: "bypassPermissions"), d, none, false, false),
            ("plan", bash("npm install", mode: "plan"), d, none, false, false),
            ("dontAsk", bash("npm install", mode: "dontAsk"), d, none, false, false),
            ("acceptEdits + Edit", call("Edit", edit, mode: "acceptEdits"), d, none, false, false),
            ("acceptEdits + Bash", bash("npm install", mode: "acceptEdits"), d, none, false, true),
            ("Edit, default mode", call("Edit", edit), d, none, false, true),
            ("deny rule names tool", bash("npm install"), d, SettingsRules(allow: [], deny: ["Bash(rm:*)"]), false, false),
            ("simple allow", bash("npm install"), d, SettingsRules(allow: ["Bash(npm install:*)"], deny: []), false, false),
            ("non-matching allow", bash("npm install"), d, SettingsRules(allow: ["Bash(npm test:*)"], deny: []), false, true),
            ("riskyOnly + low", bash("ls -la"), s { $0.gateScope = .riskyOnly }, none, false, false),
            ("riskyOnly + med", bash("npm install"), s { $0.gateScope = .riskyOnly }, none, false, true),
            ("automatic + auto + low", bash("ls -la", mode: "auto"), d, none, false, false),
            ("automatic + default + low", bash("ls -la"), d, none, false, true),
            ("full + auto + low", bash("ls -la", mode: "auto"), s { $0.gateScope = .full }, none, false, true),
            ("awayMode beats presence", bash("npm install"), s { $0.awayMode = true }, none, true, true),
            ("race category", call("mcp__github__create_issue", ["title": "x"]), d, none, false, false),
            ("notify category", call("WebFetch", ["url": "https://x.com"]), d, none, false, false),
            ("paused", bash("npm install"), s { $0.paused = true }, none, false, false),
        ] + ["Read", "Grep", "Glob", "LS", "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet"].map {
            ("read-only \($0)", call($0, [:]), d, none, false, false)
        }
        for (label, input, settings, rules, present, expectHold) in rows {
            let h = Harness(gated, settings: settings); h.rec.rules = rules
            if present { h.present() } else { h.away() }
            XCTAssertEqual(h.broker.gate(input, meta: ui) != .pass, expectHold, label)
            if expectHold {
                XCTAssertEqual(h.broker.pending.map(\.channel), [.gate], label)
                XCTAssertTrue(h.held.isEmpty, label + ": announced only after attach (A2)")
            }
        }
        for meta in [HookMeta(pid: nil, host: cursor, entrypoint: "sdk-py"), HookMeta(pid: nil, host: "com.apple.Terminal", entrypoint: "cli")] {
            let h = Harness(gated); h.away()
            XCTAssertEqual(h.broker.gate(bash("npm install"), meta: meta), .pass); XCTAssertTrue(h.broker.pending.isEmpty)
        }
    }
    func testPresenceReleaseNeedsThreeContinuousSeconds() {
        let h = Harness(gated); h.away()
        let (id, w) = h.holdAttached(bash("npm install"), gate: true)
        h.present(); h.tick(0); h.tick(2.0)
        h.away(); h.tick(0.5)                                   // left Cursor: the 3 s starts again
        h.present(); h.tick(0); h.tick(2.9)
        XCTAssertEqual(h.broker.pending.map(\.id), [id]); XCTAssertTrue(w.bodies.isEmpty)
        h.tick(0.1)
        XCTAssertEqual(w.bodies, [nil]); XCTAssertEqual(h.statuses, [.movedToCursor])
        let r = Harness([.Bash: .race]); r.present()            // Channel 1: presence changes attention only
        let (rid, _) = r.holdAttached(bash("npm install"))
        r.tick(0); r.tick(10); XCTAssertEqual(r.broker.pending.map(\.id), [rid])
        let am = Harness(gated, settings: s { $0.awayMode = true }); am.present()
        let (aid, _) = am.holdAttached(bash("npm install"), gate: true)
        am.tick(0); am.tick(10); XCTAssertEqual(am.broker.pending.map(\.id), [aid])
    }
    func testFiftyRequestQueueOldestFirstEachResolvable() {   // spec §13
        let h = Harness(gated); h.away()
        var ids: [String] = [], waiters: [FakeWaiter] = []
        for i in 0..<50 {
            let (id, w) = h.holdAttached(bash("npm install pkg\(i)"), gate: true)
            ids.append(id); waiters.append(w); h.clock.advance(1)
        }
        XCTAssertEqual(h.broker.pending.map(\.id), ids)
        XCTAssertEqual(h.broker.resolve(id: ids[25], decision: .deny(note: nil), source: .click), .applied)
        XCTAssertEqual(h.broker.pending.map(\.id), ids.enumerated().filter { $0.offset != 25 }.map(\.element))
        for (i, id) in ids.enumerated() where i != 25 { XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .applied) }
        XCTAssertTrue(h.broker.pending.isEmpty); XCTAssertTrue(waiters.allSatisfy { $0.bodies.count == 1 })
    }
}
