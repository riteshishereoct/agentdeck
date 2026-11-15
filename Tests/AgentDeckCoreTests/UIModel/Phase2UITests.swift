import XCTest
@testable import AgentDeckCore

final class QuestionFormTests: XCTestCase {
    let input = try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"questions":[{"question":"DB?","options":[{"label":"Mongo"},{"label":"Postgres"}]},{"question":"Envs?","multiSelect":true,"options":[{"label":"dev"},{"label":"prod"}]}]}"#.utf8))
    func testAnswersRequireEveryQuestionAndPreserveOptionOrder() {
        let specs = QuestionForm.parse(input)
        XCTAssertEqual(specs.map(\.question), ["DB?", "Envs?"])
        XCTAssertNil(QuestionForm.answers(specs, QuestionSelection(chosen: ["DB?": [0]])))
        XCTAssertEqual(QuestionForm.answers(specs, QuestionSelection(chosen: ["DB?": [1], "Envs?": [1, 0]])), ["DB?": "Postgres", "Envs?": "dev, prod"])
        XCTAssertEqual(QuestionForm.answers(specs, QuestionSelection(chosen: ["Envs?": [0]], other: ["DB?": "  SQLite  "])), ["DB?": "SQLite", "Envs?": "dev"])
    }
    func testMalformedAndAmbiguousQuestionsFailClosed() {
        XCTAssertTrue(QuestionForm.parse(.object([:])).isEmpty)
        XCTAssertTrue(QuestionForm.parse(.object(["questions": .array([.object(["question": .string(" ")])])])).isEmpty)
        XCTAssertTrue(QuestionForm.parse(.object(["questions": .array([.object(["question": .string("X")]), .object(["question": .string("X")])])])).isEmpty)
        XCTAssertNil(QuestionForm.answers([], QuestionSelection()))
        XCTAssertNil(QuestionForm.answers(QuestionForm.parse(input), QuestionSelection(chosen: ["DB?": [0, 1], "Envs?": [0]])))
        XCTAssertNil(QuestionForm.answers(QuestionForm.parse(input), QuestionSelection(chosen: ["DB?": [3], "Envs?": [0]])))
    }
    func testAnswerActionsAreCompleteArmedAndClickOnly() {
        let c = FakeClock(); let q = CardQueue(clock: c)
        let r = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate, input: input)
        q.sync(pending: [r], context: QueueContext(expanded: true)); q.didRender(topId: "Q")
        let answers = ["DB?": "Mongo", "Envs?": "dev"]
        XCTAssertEqual(q.perform(.answer(answers), renderedId: "Q", via: .click), .dropped(.notArmed))
        c.advance(1)
        XCTAssertEqual(q.perform(.answer(answers), renderedId: "Q", via: .click), .send(requestId: "Q", decision: .answer(answers), source: .click))
        XCTAssertEqual(q.perform(.answer(["DB?": "Mongo"]), renderedId: "Q", via: .click), .dropped(.notApplicable))
        XCTAssertEqual(q.perform(.answer(answers), renderedId: "Q", via: .hotkey), .dropped(.notApplicable))
        XCTAssertEqual(q.perform(.allow, renderedId: "Q", via: .hotkey), .dropped(.notApplicable))
        XCTAssertEqual(CardLayout.buttons(for: r), [.submitAnswer, .openInCursor])
        let notice = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .notify, input: input)
        XCTAssertEqual(CardLayout.buttons(for: notice), [.answerInCursor, .dismiss])
        let person = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate, personOnly: true, input: input)
        XCTAssertEqual(CardLayout.buttons(for: person), [.answerInCursor, .dismiss])
    }
    func testMalformedGateQuestionRemainsReadOnly() {
        let r = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate)
        XCTAssertEqual(CardLayout.buttons(for: r), [.answerInCursor, .dismiss])
    }
}

final class AllowAlwaysUITests: XCTestCase {
    let suggestion: JSONValue = .object(["type": .string("addRules"), "rules": .array([.object(["toolName": .string("Bash"), "ruleContent": .string("npm test:*")])]), "behavior": .string("allow"), "destination": .string("localSettings")])
    func testOnlyOfferedRuleCanBeSentAndHighRiskNeedsHold() {
        let c = FakeClock(); let q = CardQueue(clock: c)
        let r = UI.request("A", risk: .high, suggestions: [suggestion])
        q.sync(pending: [r], context: QueueContext(expanded: true)); q.didRender(topId: "A")
        XCTAssertEqual(q.perform(.allowAlways(suggestion), renderedId: "A", via: .hold), .dropped(.notArmed))
        c.advance(1)
        XCTAssertEqual(q.perform(.allowAlways(suggestion), renderedId: "A", via: .click), .dropped(.needsHold))
        XCTAssertEqual(q.perform(.allowAlways(suggestion), renderedId: "A", via: .hotkey), .dropped(.notApplicable))
        XCTAssertEqual(q.perform(.allowAlways(.object([:])), renderedId: "A", via: .hold), .dropped(.notApplicable))
        XCTAssertEqual(q.perform(.allowAlways(suggestion), renderedId: "A", via: .hold), .send(requestId: "A", decision: .allowAlways(suggestion: suggestion), source: .holdConfirmed))
        XCTAssertEqual(CardLayout.buttons(for: r), [.allow, .allowAlways(rule: "Bash(npm test:*) · in this project (your local settings)", suggestion: suggestion), .deny, .denyWithNote, .openInCursor])
    }
    func testGatePersonOnlyAndNoticeNeverOfferPersistentApproval() {
        for r in [UI.request("A", hook: .preToolUse, channel: .gate, suggestions: [suggestion]), UI.request("B", personOnly: true, suggestions: [suggestion]), UI.request("C", channel: .notify, suggestions: [suggestion])] {
            XCTAssertFalse(CardLayout.buttons(for: r).contains { if case .allowAlways = $0 { return true }; return false })
        }
    }
    func testHiddenCardDropsClickAfterItWasArmed() {
        let c = FakeClock(); let q = CardQueue(clock: c)
        q.sync(pending: [UI.request("A")], context: QueueContext(expanded: true)); q.didRender(topId: "A"); c.advance(1)
        q.sync(context: QueueContext(expanded: true, privacy: true))
        XCTAssertEqual(q.perform(.deny(note: nil), renderedId: "A", via: .click), .dropped(.staleCard))
    }
}

final class RichRowTests: XCTestCase {
    func testProgressIsNeverInventedAndInternalAgentsHidden() {
        XCTAssertEqual(RowDetail.progress(UI.session(stepCount: 7, progress: TaskProgress(done: 4, total: 7))), .bar(done: 4, total: 7))
        XCTAssertEqual(RowDetail.progress(UI.session(stepCount: 7, activity: [0, 2, 4])), .steps(count: 7, spark: "▁▄█"))
        XCTAssertEqual(RowDetail.sparkline([0, 0]), "")
        XCTAssertEqual(RowDetail.sparkline([-1, 1]), "▁█")
        let s = UI.session(subagents: [Agent(id: "1", type: "review", startedAt: UI.t0), Agent(id: "2", type: "", startedAt: UI.t0), Agent(id: "3", type: "tests", state: .ended, startedAt: UI.t0)])
        XCTAssertEqual(RowDetail.subagentLine(s), "2 subagents · review ● · tests ○")
        XCTAssertEqual(RowDetail.visibleSubagents(s).map(\.id), ["1", "3"])
        XCTAssertEqual(RowDetail.degradedBadge(UI.session(degraded: true)), "hooks degraded")
    }
    func testYourTurnFoldsWithoutReappearingUntilNextTurn() {
        let c = FakeClock(); var t = YourTurnTracker(clock: c)
        t.update([UI.session("a", state: .yourTurn, summary: "Tests passed")])
        XCTAssertEqual(t.visible().map(\.text), ["Tests passed"])
        c.advance(10); t.update([UI.session("a", state: .yourTurn)])
        XCTAssertTrue(t.visible().isEmpty)
        t.update([UI.session("a", state: .working)]); t.update([UI.session("a", state: .yourTurn)])
        XCTAssertEqual(t.visible().map(\.text), ["Done"])
        t.dismiss(sessionId: "a"); t.update([UI.session("a", state: .yourTurn)])
        XCTAssertTrue(t.visible().isEmpty)
    }
}

final class AttentionTests: XCTestCase {
    func testBoundariesAndOnceOnlyNotifications() {
        for (age, stage) in [(0.0, AttentionStage.expandGlow), (29.9, .expandGlow), (30, .pulse), (89.9, .pulse), (90, .notify), (589.9, .notify), (590, .waitingInCursor)] {
            XCTAssertEqual(AttentionLadder.stage(age: age), stage)
        }
        var t = AttentionTracker(); let r = UI.request("A")
        XCTAssertTrue(t.dueForNotification([r], mutedIds: [], quiet: false, now: UI.t0.addingTimeInterval(89)).isEmpty)
        XCTAssertTrue(t.pulsing([r], mutedIds: [], now: UI.t0.addingTimeInterval(30)))
        XCTAssertEqual(t.dueForNotification([r], mutedIds: [], quiet: false, now: UI.t0.addingTimeInterval(90)).map(\.id), ["A"])
        XCTAssertTrue(t.dueForNotification([r], mutedIds: [], quiet: false, now: UI.t0.addingTimeInterval(100)).isEmpty)
        XCTAssertTrue(t.dueForNotification([UI.request("B")], mutedIds: ["B"], quiet: false, now: UI.t0.addingTimeInterval(100)).isEmpty)
        XCTAssertTrue(t.dueForNotification([UI.request("C")], mutedIds: [], quiet: true, now: UI.t0.addingTimeInterval(100)).isEmpty)
        XCTAssertTrue(t.dueForNotification([UI.request("D")], mutedIds: [], quiet: false, now: UI.t0.addingTimeInterval(590)).isEmpty)
    }
    func testNotificationsNeverApproveAndPrivacyHidesContent() {
        XCTAssertEqual(NotificationPlan.actionIds(forCategory: NotificationPlan.decideCategory), ["deny", "show"])
        XCTAssertEqual(NotificationPlan.actionIds(forCategory: NotificationPlan.noticeCategory), ["show"])
        XCTAssertEqual(NotificationPlan.actionIds(forCategory: "unknown"), [])
        XCTAssertEqual(NotificationPlan.category(for: UI.request("A", channel: .notify)), NotificationPlan.noticeCategory)
        let r = UI.request("A", preview: "secret command")
        let p = NotificationPlan.content(for: r, session: UI.session(project: "secret-proj"), sessionIndex: 2, privacy: true)
        XCTAssertEqual(p.title, "Session 2 needs approval"); XCTAssertEqual(p.body, "Bash")
        XCTAssertEqual(NotificationPlan.requestId(from: NotificationPlan.userInfo(for: r)), "A")
        XCTAssertNil(NotificationPlan.requestId(from: ["requestId": 42]))
        XCTAssertLessThanOrEqual(NotificationPlan.content(for: UI.request("A", preview: String(repeating: "x", count: 200)), session: nil, sessionIndex: 1, privacy: false).body.count, 80)
    }
}

final class PrivacyTests: XCTestCase {
    func testPrivateRowsAndCountsHideSessionContent() {
        let s = UI.session(project: "secret-proj", state: .needsYou, title: "secret-title", summary: "secret-summary", pending: [UI.request("A", tool: "mcp__db__query", preview: "secret command")])
        XCTAssertEqual(PrivacyFormat.row(index: 2, session: s), "Session 2 needs approval · db.query")
        XCTAssertEqual(PrivacyFormat.pill([s]), "1 needs you")
        XCTAssertEqual(PrivacyFormat.row(index: 1, session: UI.session(state: .yourTurn)), "Session 1 ready for you")
        let resolved = UI.session(state: .working, pending: [UI.request("A", status: .handledElsewhere)])
        XCTAssertEqual(PrivacyFormat.row(index: 3, session: resolved), "Session 3 working")
    }
}
