import XCTest
@testable import AgentDeckCore

final class CardQueueTests: XCTestCase {
    var clock: FakeClock!; var q: CardQueue!
    let open = QueueContext(expanded: true)
    override func setUp() { clock = FakeClock(); q = CardQueue(clock: clock) }

    func testOldestFirstAndNewArrivalNeverBecomesTop() {
        _ = q.sync(pending: [UI.request("B", at: UI.t0.addingTimeInterval(5)), UI.request("A")], context: open)
        XCTAssertEqual(q.ordered.map(\.id), ["A", "B"]); XCTAssertEqual(q.top?.id, "A"); XCTAssertEqual(q.positionText, "1 of 2")
        let arrivals = q.sync(pending: q.ordered + [UI.request("C", at: UI.t0.addingTimeInterval(9))], context: open)
        XCTAssertEqual(arrivals.map(\.id), ["C"]); XCTAssertEqual(q.top?.id, "A")
    }
    func testPickedRequestIsShownAndDecidedAndRearms_LiveBug2ndRequest() {
        let a = UI.request("A"), b = UI.request("B", at: UI.t0.addingTimeInterval(1)), c = UI.request("C", at: UI.t0.addingTimeInterval(2))
        _ = q.sync(pending: [a, b, c], context: open); q.didRender(topId: "A"); clock.advance(1)
        XCTAssertEqual(q.positionText, "1 of 3"); XCTAssertEqual(q.nextId, "B")
        _ = q.sync(context: QueueContext(expanded: true, revealedId: "B"))      // the person picks B
        XCTAssertEqual(q.top?.id, "B"); XCTAssertEqual(q.positionText, "2 of 3"); XCTAssertEqual(q.nextId, "C")
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.staleCard))   // a late click on A's card never lands on B
        q.didRender(topId: "B")
        XCTAssertEqual(q.perform(.allow, renderedId: "B", via: .click), .dropped(.notArmed))     // arming restarts for B
        clock.advance(0.6)
        XCTAssertEqual(q.perform(.allow, renderedId: "B", via: .click), .send(requestId: "B", decision: .allow, source: .click))
        _ = q.sync(pending: [a, c], context: QueueContext(expanded: true, revealedId: "B"))     // B resolved: back to arrival order
        XCTAssertEqual(q.top?.id, "A"); XCTAssertEqual(q.nextId, "C")
    }
    func testNonPendingStatusesAreNotQueued() {
        _ = q.sync(pending: [UI.request("A", status: .handledElsewhere), UI.request("B")], context: open)
        XCTAssertEqual(q.ordered.map(\.id), ["B"])
    }
    func testAllowArmsAfter600msOfVisibility() {
        _ = q.sync(pending: [UI.request("A")], context: open); q.didRender(topId: "A")
        clock.advance(0.599)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.notArmed))
        clock.advance(0.001)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .send(requestId: "A", decision: .allow, source: .click))
    }
    func testCollapsedCardNeverArms() {
        _ = q.sync(pending: [UI.request("A")], context: QueueContext(expanded: false)); clock.advance(5)
        XCTAssertFalse(q.isArmed)
    }
    func testTopChangesAt590msDropsHotkeyAndRearmsAfter600ms_ReviewFocus5() {   // (Review Focus #5)
        _ = q.sync(pending: [UI.request("A"), UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open); q.didRender(topId: "A")
        clock.advance(0.59)
        _ = q.sync(pending: [UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open)      // A resolved elsewhere, B is top now
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .dropped(.staleCard))     // view still shows A
        q.didRender(topId: "B")
        XCTAssertEqual(q.perform(.allow, renderedId: "B", via: .hotkey), .dropped(.notArmed))
        clock.advance(0.599)
        XCTAssertEqual(q.perform(.allow, renderedId: "B", via: .hotkey), .dropped(.notArmed))
        clock.advance(0.001)
        XCTAssertEqual(q.perform(.allow, renderedId: "B", via: .hotkey), .send(requestId: "B", decision: .allow, source: .hotkey))
    }
    func testResolvedElsewhereBetweenRenderAndClickIsDroppedNeverPassedOn_ReviewFocus5() {   // (Review Focus #5)
        _ = q.sync(pending: [UI.request("A"), UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open); q.didRender(topId: "A")
        clock.advance(2)
        _ = q.sync(pending: [UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.staleCard))
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "A", via: .click), .dropped(.staleCard))
        XCTAssertEqual(q.perform(.allow, renderedId: nil, via: .click), .dropped(.staleCard))
    }
    func testHotkeyOnlyExpandsWhenCollapsedQuietOrPrivacy() {
        for ctx in [QueueContext(expanded: false), QueueContext(expanded: true, quiet: true), QueueContext(expanded: true, privacy: true)] {
            _ = q.sync(pending: [UI.request("A")], context: ctx); clock.advance(5)
            XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .expandOnly(revealId: nil))
            XCTAssertEqual(q.perform(.deny(note: nil), renderedId: nil, via: .hotkey), .expandOnly(revealId: nil))
        }
    }
    func testMutedRowHotkeyRevealsThenDecidesOnlyAfterArming() {
        let muted = QueueContext(expanded: true, mutedIds: ["A"])
        _ = q.sync(pending: [UI.request("A")], context: muted); clock.advance(5)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .expandOnly(revealId: "A"))
        _ = q.sync(context: QueueContext(expanded: true, mutedIds: ["A"], revealedId: "A")); q.didRender(topId: "A")
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .dropped(.notArmed))
        clock.advance(0.6)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .send(requestId: "A", decision: .allow, source: .hotkey))
    }
    func testHighRiskRules() {
        _ = q.sync(pending: [UI.request("H", risk: .high)], context: open); q.didRender(topId: "H"); clock.advance(1)
        XCTAssertEqual(q.perform(.allow, renderedId: "H", via: .hotkey), .dropped(.highRiskHotkey))
        XCTAssertEqual(q.perform(.allow, renderedId: "H", via: .click), .dropped(.needsHold))
        XCTAssertEqual(q.perform(.allow, renderedId: "H", via: .hold), .send(requestId: "H", decision: .allow, source: .holdConfirmed))
        XCTAssertEqual(q.perform(.deny(note: "no"), renderedId: "H", via: .hotkey), .send(requestId: "H", decision: .deny(note: "no"), source: .hotkey))
    }
    func testPersonOnlyAllowDroppedDenyOk() {
        _ = q.sync(pending: [UI.request("P", personOnly: true)], context: open); q.didRender(topId: "P"); clock.advance(1)
        XCTAssertEqual(q.perform(.allow, renderedId: "P", via: .click), .dropped(.personOnly))
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "P", via: .click), .send(requestId: "P", decision: .deny(note: nil), source: .click))
    }
    func testNotifyChannelHasNoActions() {
        _ = q.sync(pending: [UI.request("N", channel: .notify)], context: open); q.didRender(topId: "N"); clock.advance(1)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "N", via: .click), .dropped(.notApplicable))
    }
    func testOverflowingCommandCannotBypassHoldViaClickOrHotkey() {
        let r = Request(id: "long", sessionId: "s", kind: .permission, hook: .permissionRequest, tool: "Bash", preview: "long",
                        fullInput: .object(["command": .string(String(repeating: "echo hello\n", count: 15))]), risk: Risk(level: .low, reason: "routine"),
                        channel: .race, createdAt: UI.t0)
        q.sync(pending: [r], context: open); q.didRender(topId: r.id); clock.advance(1)
        XCTAssertEqual(q.perform(.allow, renderedId: r.id, via: .click), .dropped(.needsHold))
        XCTAssertEqual(q.perform(.allow, renderedId: r.id, via: .hotkey), .dropped(.highRiskHotkey))
        XCTAssertEqual(q.perform(.allow, renderedId: r.id, via: .hold), .send(requestId: r.id, decision: .allow, source: .holdConfirmed))
    }
    func testOverflowAlsoRequiresHoldForNarrowAllowAlways() {
        let rule: JSONValue = .object(["type": .string("addRules"), "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("echo:*")])])])
        let r = Request(id: "long", sessionId: "s", kind: .permission, hook: .permissionRequest, tool: "Bash", preview: "long",
                        fullInput: .object(["command": .string(String(repeating: "echo hello\n", count: 15))]), risk: Risk(level: .low, reason: "routine"), suggestions: [rule],
                        channel: .race, createdAt: UI.t0)
        q.sync(pending: [r], context: open); q.didRender(topId: r.id); clock.advance(1)
        XCTAssertEqual(q.perform(.allowAlways(rule), renderedId: r.id, via: .click), .dropped(.needsHold))
        XCTAssertEqual(q.perform(.allowAlways(rule), renderedId: r.id, via: .hold), .send(requestId: r.id, decision: .allowAlways(suggestion: rule), source: .holdConfirmed))
    }
    func testNoCard() { XCTAssertEqual(q.perform(.allow, renderedId: nil, via: .hotkey), .dropped(.noCard)) }
    func testAllowArmsFromRenderNotFromSync_S1() {   // plan-validation S1: late draw must not shorten the 600 ms
        _ = q.sync(pending: [UI.request("A")], context: open)
        clock.advance(0.5); q.didRender(topId: "A")
        clock.advance(0.2)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.notArmed))
        clock.advance(0.4)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .send(requestId: "A", decision: .allow, source: .click))
    }
    func testNeverRenderedNeverArms_S1() {
        _ = q.sync(pending: [UI.request("A")], context: open); clock.advance(5)
        XCTAssertFalse(q.isArmed)
    }
    func testShowingTopOnlyWhenCardIsOnScreen() {
        _ = q.sync(pending: [UI.request("A")], context: QueueContext(expanded: false)); XCTAssertNil(q.showingTop)
        _ = q.sync(context: QueueContext(expanded: true, mutedIds: ["A"])); XCTAssertNil(q.showingTop)
        _ = q.sync(context: QueueContext(expanded: true, mutedIds: ["A"], revealedId: "A")); XCTAssertEqual(q.showingTop?.id, "A")
    }
    func testClippingDisarmsAndRequiresFresh600msAfterScrollingBack() {
        q.sync(pending: [UI.request("A")], context: open); q.didRender(topId: "A"); clock.advance(1)
        XCTAssertTrue(q.isArmed)
        q.sync(context: QueueContext(expanded: true, cardFullyVisible: false)); q.didRender(topId: "A")
        clock.advance(1); XCTAssertFalse(q.isArmed)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .dropped(.notArmed))
        q.sync(context: open); q.didRender(topId: "A")
        clock.advance(0.599); XCTAssertFalse(q.isArmed)
        clock.advance(0.002); XCTAssertTrue(q.isArmed)
    }
    func testDenyRequiresArmingForClickAndHotkey_L1() {   // a late click must not land on the next card
        _ = q.sync(pending: [UI.request("A"), UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open); q.didRender(topId: "A")
        clock.advance(1)
        _ = q.sync(pending: [UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open); q.didRender(topId: "B")
        clock.advance(0.1)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "B", via: .click), .dropped(.notArmed))
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "B", via: .hotkey), .dropped(.notArmed))
        clock.advance(0.5)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "B", via: .hotkey), .send(requestId: "B", decision: .deny(note: nil), source: .hotkey))
    }
    func testDenyNoteSendNeedsTheCardStillRenderedAndFullyVisible_L1() {
        _ = q.sync(pending: [UI.request("A")], context: open); q.didRender(topId: "A"); clock.advance(1)
        // Note field open; a resize hides part of the card before Send.
        q.sync(context: QueueContext(expanded: true, cardFullyVisible: false)); q.didRender(topId: nil)
        XCTAssertEqual(q.perform(.deny(note: "use printf"), renderedId: "A", via: .click), .dropped(.notArmed))
        q.sync(context: open); q.didRender(topId: "A"); clock.advance(0.3)
        XCTAssertEqual(q.perform(.deny(note: "use printf"), renderedId: "A", via: .click), .dropped(.notArmed))
        clock.advance(0.3)
        XCTAssertEqual(q.perform(.deny(note: "use printf"), renderedId: "A", via: .click), .send(requestId: "A", decision: .deny(note: "use printf"), source: .click))
    }
    func testCardFrameChangeDisarmsEveryActionFor600ms_FShift() {   // live incident 05:12:47Z: re-layout moved a card under the pointer
        let rule: JSONValue = .object(["type": .string("addRules")])
        let f1 = CGRect(x: 12, y: 40, width: 416, height: 200), f2 = CGRect(x: 12, y: 140, width: 416, height: 200)
        _ = q.sync(pending: [UI.request("A", suggestions: [rule])], context: QueueContext(expanded: true, cardFrame: f1)); q.didRender(topId: "A")
        clock.advance(5); XCTAssertTrue(q.isArmed)
        q.sync(context: QueueContext(expanded: true, cardFrame: f1)); q.didRender(topId: "A")   // same frame: stays armed
        XCTAssertTrue(q.isArmed)
        q.sync(context: QueueContext(expanded: true, cardFrame: f2)); q.didRender(topId: "A")   // moved at t
        clock.advance(0.599)
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.notArmed))
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .hotkey), .dropped(.notArmed))
        XCTAssertEqual(q.perform(.allowAlways(rule), renderedId: "A", via: .click), .dropped(.notArmed))
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "A", via: .click), .dropped(.notArmed))
        q.sync(context: QueueContext(expanded: true, cardFrame: f2)); q.didRender(topId: "A")   // stable frame does not restart the clock
        clock.advance(0.001)
        XCTAssertEqual(q.perform(.allowAlways(rule), renderedId: "A", via: .click), .send(requestId: "A", decision: .allowAlways(suggestion: rule), source: .click))
    }
    func testQuestionAnswerDisarmsWhenCardResizes_FShift() {
        let input: JSONValue = .object(["questions": .array([.object(["question": .string("DB?"), "options": .array([.object(["label": .string("Mongo")]), .object(["label": .string("Postgres")])])])])])
        let r = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate, input: input)
        _ = q.sync(pending: [r], context: QueueContext(expanded: true, cardFrame: CGRect(x: 0, y: 0, width: 400, height: 200))); q.didRender(topId: "Q")
        clock.advance(2)
        q.sync(context: QueueContext(expanded: true, cardFrame: CGRect(x: 0, y: 0, width: 400, height: 260))); q.didRender(topId: "Q")
        XCTAssertEqual(q.perform(.answer(["DB?": "Mongo"]), renderedId: "Q", via: .click), .dropped(.notArmed))
        clock.advance(0.6)
        XCTAssertEqual(q.perform(.answer(["DB?": "Mongo"]), renderedId: "Q", via: .click), .send(requestId: "Q", decision: .answer(["DB?": "Mongo"]), source: .click))
    }
    func testOneFrameClipRestartsArmingAndBindingStaysExact() {
        _ = q.sync(pending: [UI.request("A"), UI.request("B", at: UI.t0.addingTimeInterval(1))], context: open); q.didRender(topId: "A")
        clock.advance(5); XCTAssertTrue(q.isArmed)
        q.sync(context: QueueContext(expanded: true, cardFullyVisible: false)); q.didRender(topId: nil)
        XCTAssertNil(q.renderedId)
        XCTAssertEqual(q.perform(.allow, renderedId: q.renderedId, via: .hotkey), .dropped(.staleCard))
        q.sync(context: open); q.didRender(topId: "A")
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.notArmed))
        clock.advance(0.6)
        XCTAssertEqual(q.perform(.allow, renderedId: "B", via: .click), .dropped(.staleCard))
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .send(requestId: "A", decision: .allow, source: .click))
    }


    // M1: once the panel is hidden, an action decided on the pre-hide context must not send.
    func testHiddenPanelDropsActionsImmediatelyAfterContextSync() {
        _ = q.sync(pending: [UI.request("A")], context: open); q.didRender(topId: "A"); clock.advance(1)
        XCTAssertTrue(q.isArmed)
        q.sync(context: QueueContext(expanded: false, cardFullyVisible: false)); q.didRender(topId: nil)
        XCTAssertFalse(q.isArmed)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "A", via: .hotkey), .expandOnly(revealId: nil))
        XCTAssertEqual(q.perform(.allow, renderedId: "A", via: .click), .dropped(.staleCard))
    }
    // L1: the Deny hotkey only stands in for a Deny button the card shows.
    func testDenyHotkeyRefusedOnGateQuestionCardWithoutDenyButton() {
        let question = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate,
                                  input: .object(["questions": .array([.object(["question": .string("Colour?"), "options": .array([.object(["label": .string("Blue")])])])])]))
        XCTAssertFalse(CardLayout.buttons(for: question).contains(.deny))
        _ = q.sync(pending: [question], context: open); q.didRender(topId: "Q"); clock.advance(1)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "Q", via: .hotkey), .dropped(.notApplicable))
    }
    // L2: the Deny hotkey must not silently discard an open note draft; the note's own Send still works.
    func testDenyHotkeyRefusedWhileNoteEditorOpen() {
        let ctx = QueueContext(expanded: true, noteEditingId: "A")
        _ = q.sync(pending: [UI.request("A")], context: ctx); q.didRender(topId: "A"); clock.advance(1)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "A", via: .hotkey), .dropped(.noteOpen))
        XCTAssertEqual(q.perform(.deny(note: "use npm ci"), renderedId: "A", via: .click),
                       .send(requestId: "A", decision: .deny(note: "use npm ci"), source: .click))
        q.sync(context: open)
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "A", via: .hotkey), .send(requestId: "A", decision: .deny(note: nil), source: .hotkey))
    }
}
