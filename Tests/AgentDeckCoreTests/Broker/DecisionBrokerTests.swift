import XCTest
@testable import AgentDeckCore

final class DecisionBrokerTests: XCTestCase {
    func testScopingPassesWithoutNotice() {
        var paused = AppSettings(); paused.paused = true
        var others = AppSettings(); others.gateOtherHosts = true
        let iterm = HookMeta(pid: nil, host: "com.googlecode.iterm2", entrypoint: "cli")
        let rows: [(AppSettings, HookMeta, Bool)] = [            // settings, meta, expect HOLD
            (paused, ui, false),
            (AppSettings(), HookMeta(pid: nil, host: cursor, entrypoint: "sdk-cli"), false),
            (AppSettings(), HookMeta(pid: nil, host: cursor, entrypoint: "sdk-ts"), false),
            (AppSettings(), iterm, false),
            (AppSettings(), HookMeta(pid: nil, host: nil, entrypoint: nil), false),
            (AppSettings(), HookMeta(pid: nil, host: cursor, entrypoint: nil), true),   // nil entrypoint = interactive
            (others, iterm, true),
        ]
        for (i, (s, meta, expectHold)) in rows.enumerated() {
            let h = Harness([.Bash: .race], settings: s)
            XCTAssertEqual(h.broker.decide(bash("npm install"), meta: meta) != .pass, expectHold, "row \(i)")
            XCTAssertEqual(h.broker.pending.isEmpty, !expectHold, "row \(i): scoped out means no notice either")
        }
    }
    func testDecideHoldsOnRaceElsePassesWithNotice() {
        let h = Harness([.Bash: .race])
        let id = h.hold(h.broker.decide(bash("npm install"), meta: ui))
        XCTAssertEqual(id.count, 36); XCTAssertEqual(h.broker.pending.map(\.id), [id])
        XCTAssertTrue(h.held.isEmpty, "A2: no card until a live waiter is attached")
        XCTAssertTrue(h.broker.attach(id: id, waiter: FakeWaiter()))
        XCTAssertEqual(h.held.map(\.channel), [.race]); XCTAssertEqual(h.held[0].kind, .permission); XCTAssertEqual(h.held[0].hook, .permissionRequest)
        let n = Harness()
        XCTAssertEqual(n.broker.decide(bash("npm install"), meta: ui), .pass)
        XCTAssertEqual(n.broker.pending.map(\.channel), [.notify]); XCTAssertEqual(n.held.count, 1)   // notices are emitted at once
    }
    func testAttachOnceAndHookGoneAfterTwoSeconds() {
        let h = Harness([.Bash: .race])
        let id = h.hold(h.broker.decide(bash("npm install"), meta: ui))
        XCTAssertTrue(h.broker.attach(id: id, waiter: FakeWaiter()))
        XCTAssertFalse(h.broker.attach(id: id, waiter: FakeWaiter()))
        XCTAssertFalse(h.broker.attach(id: "nope", waiter: FakeWaiter()))
        let late = h.hold(h.broker.decide(bash("npm ci"), meta: ui))
        h.tick(1.9); XCTAssertEqual(h.broker.pending.count, 2)
        h.tick(0.1); XCTAssertEqual(h.broker.pending.map(\.id), [id]); XCTAssertEqual(h.statuses, [.hookGone])
        XCTAssertEqual(h.held.map(\.id), [id], "the unattached hold never reached the store")
        XCTAssertFalse(h.broker.attach(id: late, waiter: FakeWaiter()))
        let other = h.hold(h.broker.decide(bash("npm i x"), meta: ui))
        h.clock.advance(2.1)                                    // no tick: attach enforces the 2 s window itself
        XCTAssertFalse(h.broker.attach(id: other, waiter: FakeWaiter()))
        let n = Harness(); _ = n.broker.decide(bash("ls"), meta: ui)
        XCTAssertFalse(n.broker.attach(id: n.broker.pending[0].id, waiter: FakeWaiter()))   // notices hold no hook
    }
    func testTimeoutReleaseAndWaiterClosed() {
        let h = Harness([.Bash: .race])
        let (a, wa) = h.holdAttached(bash("npm install"))
        let (b, wb) = h.holdAttached(bash("npm ci"))
        h.broker.waiterClosed(id: b)
        XCTAssertEqual(h.statuses, [.handledElsewhere]); XCTAssertTrue(wb.bodies.isEmpty)
        h.tick(589.9); XCTAssertEqual(h.broker.pending.map(\.id), [a])
        h.tick(0.1); XCTAssertEqual(wa.bodies, [nil]); XCTAssertEqual(h.statuses, [.handledElsewhere, .timedOut])
        h.broker.waiterClosed(id: a)                            // after release: no-op
        XCTAssertEqual(h.statuses.count, 2); XCTAssertTrue(h.broker.pending.isEmpty)
    }
    func testResolveIsOneShotAndNeedsAnOpenHook() {
        let h = Harness([.Bash: .race])
        let (id, w) = h.holdAttached(bash("npm install"))
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .applied)
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .dropped(.unknownOrResolved))   // double click
        XCTAssertEqual(w.bodies.compactMap { $0 }.map(json), [envelope("permission-allow")]); XCTAssertEqual(h.statuses, [.allowed])
        XCTAssertEqual(w.bodies.count, 1, "the waiter hears exactly one decision")
        let unattached = h.hold(h.broker.decide(bash("npm ci"), meta: ui))
        XCTAssertEqual(h.broker.resolve(id: unattached, decision: .deny(note: nil), source: .click), .dropped(.unknownOrResolved))
    }
    func testLateClickAfterWaiterClosedIsDropped() {
        let h = Harness([.Bash: .race])
        let (id, w) = h.holdAttached(bash("npm install"))
        h.broker.waiterClosed(id: id)                           // answered in Cursor: the hook went away
        XCTAssertEqual(h.statuses, [.handledElsewhere])
        XCTAssertEqual(h.broker.resolve(id: id, decision: .allow, source: .click), .dropped(.unknownOrResolved))
        XCTAssertTrue(w.bodies.isEmpty, "nothing is ever written to a closed waiter")
        XCTAssertEqual(h.statuses, [.handledElsewhere])
    }
    func testResolveSafetyRules() {
        let h = Harness([.Bash: .race])
        let po = h.holdAttached(bash("npm install", extra: ["person_only": true])).0
        XCTAssertEqual(h.broker.resolve(id: po, decision: .allow, source: .click), .dropped(.personOnly))
        XCTAssertEqual(h.broker.resolve(id: po, decision: .deny(note: nil), source: .click), .applied)
        let hi = h.holdAttached(bash("rm -rf build")).0
        for s in [DecisionSource.click, .hotkey] { XCTAssertEqual(h.broker.resolve(id: hi, decision: .allow, source: s), .dropped(.needsHoldConfirm)) }
        XCTAssertEqual(h.broker.resolve(id: hi, decision: .allow, source: .holdConfirmed), .applied)
        let n = h.holdAttached(bash("npm ci")).0
        XCTAssertEqual(h.broker.resolve(id: n, decision: .allow, source: .notification), .dropped(.notAllowedFromSource))
        XCTAssertEqual(h.broker.resolve(id: n, decision: .answer(["q": "a"]), source: .click), .dropped(.notApplicable))
        XCTAssertEqual(h.broker.resolve(id: n, decision: .deny(note: "no"), source: .notification), .applied)
        let notice = Harness(); _ = notice.broker.decide(bash("ls"), meta: ui)
        XCTAssertEqual(notice.broker.resolve(id: notice.broker.pending[0].id, decision: .deny(note: nil), source: .click), .dropped(.notApplicable))
    }
    func testEveryStatusChangeIsEmitted() {
        let h = Harness([.Bash: .race])
        let (id, _) = h.holdAttached(bash("npm install"))
        _ = h.broker.resolve(id: id, decision: .deny(note: nil), source: .click)
        XCTAssertEqual(h.rec.events.count, 2)
        guard case .requestHeld(let r) = h.rec.events[0].kind, case .requestUpdated(let rid, .denied) = h.rec.events[1].kind else { return XCTFail() }
        XCTAssertEqual([r.id, rid], [id, id]); XCTAssertEqual(h.rec.events[1].sessionId, "s1")
    }
    func testUnverifiedPermissionModePassesWithNoticeNeverHolds() {            // amendment A4
        for mode in [nil, "weird", ""] as [String?] {
            let h = Harness([.Bash: .race, .EditWrite: .gate]); h.away()
            var f: [String: Any] = ["session_id": "s1", "cwd": "/p", "tool_name": "Bash", "tool_input": ["command": "npm install"]]
            if let mode { f["permission_mode"] = mode }
            let i = try! HookInput.decode(JSONSerialization.data(withJSONObject: f))
            XCTAssertEqual(h.broker.decide(i, meta: ui), .pass, "mode \(mode ?? "nil")")
            XCTAssertEqual(h.broker.pending.map(\.channel), [.notify])
            f["tool_name"] = "Edit"; f["tool_input"] = ["file_path": "/p/a.swift"]
            let e = try! HookInput.decode(JSONSerialization.data(withJSONObject: f))
            XCTAssertEqual(h.broker.gate(e, meta: ui), .pass, "mode \(mode ?? "nil")")
            XCTAssertEqual(h.broker.pending.map(\.channel), [.notify, .notify])
        }
        let ok = Harness([.Bash: .race])                          // every documented mode is verified
        for m in ["default", "acceptEdits", "auto", "plan", "bypassPermissions", "dontAsk"] {
            XCTAssertNotEqual(ok.broker.decide(bash("npm install \(m)", mode: m), meta: ui), .pass, m)
        }
    }
    func testExitPlanModeIsAPlanReviewNoticeEvenOnRace() {                       // amendment A4
        let h = Harness([.ExitPlanMode: .race, .Other: .race])
        XCTAssertEqual(h.broker.decide(call("ExitPlanMode", ["plan": "1. x"]), meta: ui), .pass)
        XCTAssertEqual(h.broker.pending.map(\.kind), [.planReview]); XCTAssertEqual(h.broker.pending[0].channel, .notify)
        XCTAssertEqual(h.broker.resolve(id: h.broker.pending[0].id, decision: .allow, source: .click), .dropped(.notApplicable))
    }
    func testRequestPreviewMasksBeforeApplyingUTF8Limit() {
        let h = Harness([.Bash: .race])
        let input = bash("sk-abcdefghijklmnopqrstuv " + String(repeating: "界", count: 4000))
        let (_, _) = h.holdAttached(input)
        let preview = h.held[0].preview
        XCTAssertLessThanOrEqual(preview.utf8.count, 2048)
        XCTAssertFalse(preview.contains("abcdefghijklmnopqrstuv"))
        XCTAssertTrue(preview.contains("sk-a••••"))
    }

}
