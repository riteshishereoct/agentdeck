import XCTest
@testable import AgentDeckCore

final class HandledElsewhereTests: XCTestCase {
    func testPermissionRequestCopiesToolUseIdFromPreToolUseWithin30s() {
        let h = Harness([.Bash: .race])
        _ = h.broker.gate(bash("npm install", id: "toolu_1"), meta: ui); h.tick(10)
        _ = h.broker.decide(bash("npm install"), meta: ui)
        XCTAssertEqual(h.broker.pending.last?.toolUseId, "toolu_1")
        _ = h.broker.gate(bash("npm ci", id: "toolu_2"), meta: ui); h.tick(30.1)
        _ = h.broker.decide(bash("npm ci"), meta: ui)
        XCTAssertNil(h.broker.pending.last?.toolUseId)                        // older than 30 s
        _ = h.broker.gate(bash("npm i a", id: "toolu_3", agent: "ag1"), meta: ui)
        _ = h.broker.decide(bash("npm i a"), meta: ui)
        XCTAssertNil(h.broker.pending.last?.toolUseId)                        // different agentId
    }
    func testPermissionPromptAndParallelPostToolUseLeaveHoldPending() {   // (Review Focus #1)
        let h = Harness([.Bash: .race])
        _ = h.broker.gate(bash("npm install", id: "toolu_1"), meta: ui)
        let (id, w) = h.holdAttached(bash("npm install"))                    // correlated: toolu_1
        let (id2, w2) = h.holdAttached(bash("npm ci"))                       // uncorrelated: nil toolUseId
        h.tick(6)
        h.broker.observe(h.ev(.hook(.notification), notification: "permission_prompt"))   // F14: fires ~6 s into every ask
        h.broker.observe(h.ev(.hook(.postToolUse), id: "toolu_other"))       // async PostToolUse of a parallel call
        h.broker.observe(h.ev(.hook(.postToolUse)))                          // nil id never matches nil
        h.broker.observe(h.ev(.hook(.stop), session: "s2"))                  // another session
        h.tick(1)
        XCTAssertEqual(h.broker.pending.map(\.id), [id, id2])                // no extra notice either
        XCTAssertTrue(w.bodies.isEmpty && w2.bodies.isEmpty); XCTAssertTrue(h.statuses.isEmpty)
    }
    func testEachResolvingEventMarksHandledElsewhere() {
        let rows: [(String, EventKind, String?, String?)] = [                 // label, kind, toolUseId, agentId
            ("PostToolUse", .hook(.postToolUse), "toolu_1", nil),
            ("PostToolUseFailure", .hook(.postToolUseFailure), "toolu_1", nil),
            ("PermissionDenied", .hook(.permissionDenied), "toolu_1", nil),
            ("transcript tool_result", .transcriptToolResult(isError: false), "toolu_1", nil),
            ("UserPromptSubmit", .hook(.userPromptSubmit), nil, nil),
            ("Stop", .hook(.stop), nil, nil),
            ("SessionEnd", .hook(.sessionEnd), nil, nil),
            ("pidGone", .pidGone, nil, nil),
            ("SubagentStop same agent", .hook(.subagentStop), nil, "ag1"),
        ]
        for (label, kind, tid, agent) in rows {
            let h = Harness([.Bash: .race])
            _ = h.broker.gate(bash("npm install", id: "toolu_1", agent: "ag1"), meta: ui)
            let (_, w) = h.holdAttached(bash("npm install", agent: "ag1"))
            h.broker.observe(h.ev(kind, id: tid, agent: agent))
            XCTAssertEqual(h.statuses, [.handledElsewhere], label); XCTAssertEqual(w.bodies, [nil], label)
        }
        let h = Harness([.Bash: .race]); _ = h.holdAttached(bash("npm install", agent: "ag1"))
        h.broker.observe(h.ev(.hook(.subagentStop), agent: "ag2"))
        XCTAssertTrue(h.statuses.isEmpty)
    }
    func testBackstopNoticeAfterSixSecondsForShortTools() {
        let h = Harness()
        for (tool, id) in [("Edit", "e1"), ("Bash", "b1"), ("Task", "t1"), ("Agent", "a1"), ("WebFetch", "w1"),
                           ("WebSearch", "ws1"), ("mcp__github__create_issue", "m1")] {
            XCTAssertEqual(h.broker.gate(call(tool, [:], id: id), meta: ui), .pass)
        }
        _ = h.broker.gate(call("Write", ["file_path": "/p/b"], id: "e2"), meta: ui)
        h.tick(3); h.broker.observe(h.ev(.hook(.postToolUse), id: "e2"))
        h.tick(2.9); XCTAssertTrue(h.broker.pending.isEmpty)
        h.tick(0.1)
        XCTAssertEqual(h.broker.pending.map(\.toolUseId), ["e1"]); XCTAssertEqual(h.broker.pending[0].channel, .notify)
        h.broker.observe(h.ev(.hook(.postToolUse), id: "e1"))
        XCTAssertTrue(h.broker.pending.isEmpty); XCTAssertEqual(h.statuses, [.handledElsewhere])
        let sdk = Harness()
        _ = sdk.broker.gate(call("Edit", [:], id: "e3"), meta: HookMeta(pid: nil, host: cursor, entrypoint: "sdk-cli"))
        sdk.tick(7); XCTAssertTrue(sdk.broker.pending.isEmpty)
    }
    func testNoBackstopGuessWhereNoPromptCanAppear() {   // G-FALSE-BACKSTOP (live 04:33:54Z: slow auto-mode Edit)
        let h = Harness()
        _ = h.broker.gate(call("Edit", ["file_path": "/p/a"], id: "x1", mode: "auto"), meta: ui)
        _ = h.broker.gate(call("Edit", ["file_path": "/p/a"], id: "x2", mode: "acceptEdits"), meta: ui)
        _ = h.broker.gate(call("Write", ["file_path": "/p/a"], id: "x3", mode: "bypassPermissions"), meta: ui)
        _ = h.broker.gate(call("Read", ["file_path": "/p/a"], id: "x4"), meta: ui)
        _ = h.broker.gate(call("Edit", ["file_path": "/p/a"], id: "x5", mode: "default"), meta: ui)
        h.tick(7)
        XCTAssertEqual(h.broker.pending.map(\.toolUseId), ["x5"])
    }
    func testPermissionPromptNoticeOncePerSessionAndDismiss() {
        let h = Harness()
        h.broker.observe(h.ev(.hook(.notification), notification: "permission_prompt"))
        h.broker.observe(h.ev(.hook(.notification), notification: "permission_prompt"))
        h.broker.observe(h.ev(.hook(.notification), notification: "idle_prompt"))
        h.broker.observe(h.ev(.hook(.notification), session: "s9", notification: "permission_prompt", host: nil))  // not Cursor
        XCTAssertEqual(h.broker.pending.map(\.hook), [.notification]); XCTAssertEqual(h.broker.pending[0].channel, .notify)
        let r = Harness([.Bash: .race]); let (rid, _) = r.holdAttached(bash("npm install"))
        r.broker.dismiss(id: rid)                                             // held requests cannot be dismissed
        XCTAssertEqual(r.broker.pending.map(\.id), [rid])
        h.broker.dismiss(id: h.broker.pending[0].id)
        XCTAssertTrue(h.broker.pending.isEmpty); XCTAssertEqual(h.statuses, [.handledElsewhere])
    }
}
