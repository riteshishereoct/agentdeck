import XCTest
@testable import AgentDeckCore

final class QuestionConsentTests: XCTestCase {
    private func q(_ question: String, options: JSONValue?, multi: Bool? = nil, header: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["question": .string(question)]
        if let options { o["options"] = options }
        if let multi { o["multiSelect"] = .bool(multi) }
        if let header { o["header"] = .string(header) }
        return .object(o)
    }
    private func opts(_ labels: [String], descriptions: [String?] = []) -> JSONValue {
        .array(labels.enumerated().map { i, l in
            var o: [String: JSONValue] = ["label": .string(l)]
            if i < descriptions.count, let d = descriptions[i] { o["description"] = .string(d) }
            return .object(o)
        })
    }
    private func input(_ qs: JSONValue...) -> JSONValue { .object(["questions": .array(qs)]) }

    // (b) upstream requires 2–4 options: anything with fewer cannot be answered on the card, so it falls back to read-only.
    func testQuestionWithFewerThanTwoOptionsIsNotAnswerable() {
        XCTAssertTrue(QuestionForm.parse(input(q("DB?", options: nil))).isEmpty)
        XCTAssertTrue(QuestionForm.parse(input(q("DB?", options: .array([])))).isEmpty)
        XCTAssertTrue(QuestionForm.parse(input(q("DB?", options: opts(["Only"])))).isEmpty)
        XCTAssertTrue(QuestionForm.parse(input(q("A?", options: opts(["x", "y"])), q("B?", options: opts(["z"])))).isEmpty)   // one bad question spoils all
        let gate = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate, input: input(q("DB?", options: opts(["Only"]))))
        XCTAssertEqual(CardLayout.buttons(for: gate), [.answerInCursor, .dismiss])
    }

    func testParseKeepsHeaderDescriptionsAndMultiSelect() {
        let specs = QuestionForm.parse(input(q("Envs?", options: opts(["dev", "prod"], descriptions: ["safe", nil]), multi: true, header: "Deploy")))
        XCTAssertEqual(specs, [QuestionSpec(question: "Envs?", header: "Deploy", options: ["dev", "prod"], multiSelect: true, descriptions: ["safe", nil])])
    }

    // (a) what is visible is what is submitted: an option and an Other text never coexist for one question.
    func testChoosingAnOptionClearsOtherAndTypingOtherClearsOptions() {
        let single = QuestionSpec(question: "DB?", header: nil, options: ["Mongo", "Postgres"], multiSelect: false)
        let multi = QuestionSpec(question: "Envs?", header: nil, options: ["dev", "prod"], multiSelect: true)
        var s = QuestionSelection()
        s.setOther("SQLite", for: single)
        s.toggle(1, in: single)
        XCTAssertNil(s.other["DB?"]); XCTAssertEqual(s.chosen["DB?"], [1])
        XCTAssertEqual(QuestionForm.answers([single], s), ["DB?": "Postgres"])
        s.setOther("SQLite", for: single)
        XCTAssertEqual(s.chosen["DB?"], nil)
        XCTAssertEqual(QuestionForm.answers([single], s), ["DB?": "SQLite"])
        s.setOther("   ", for: single)                       // blank Other does not wipe a choice made after it
        s.toggle(0, in: single); s.setOther("  ", for: single)
        XCTAssertEqual(s.chosen["DB?"], [0])
        s.toggle(0, in: multi); s.toggle(1, in: multi); s.toggle(0, in: multi)
        XCTAssertEqual(s.chosen["Envs?"], [1])
        s.setOther("staging", for: multi)
        XCTAssertNil(s.chosen["Envs?"])
        XCTAssertEqual(QuestionForm.answers([single, multi], s), ["DB?": "Mongo", "Envs?": "staging"])
    }

    func testAHiddenOtherNeverWinsOverAVisibleChoice() {
        let single = QuestionSpec(question: "DB?", header: nil, options: ["Mongo", "Postgres"], multiSelect: false)
        XCTAssertNil(QuestionForm.answers([single], QuestionSelection(chosen: ["DB?": [0]], other: ["DB?": "SQLite"])))   // ambiguous: fail closed
    }

    // Item 4: multi-select encoding is labels in option order joined by ", " (not verified live). A label containing ", " is ambiguous.
    func testMultiSelectEncodingIsCommaSpaceJoinedInOptionOrder() {
        let multi = QuestionSpec(question: "Envs?", header: nil, options: ["dev", "qa, staging", "prod"], multiSelect: true)
        XCTAssertEqual(QuestionForm.answers([multi], QuestionSelection(chosen: ["Envs?": [2, 0]])), ["Envs?": "dev, prod"])
        XCTAssertEqual(QuestionForm.answers([multi], QuestionSelection(chosen: ["Envs?": [1, 2]])), ["Envs?": "qa, staging, prod"])   // reads as 3 answers
    }

    func testReadableQuestionTextShowsEverything() {
        let long = String(repeating: "word ", count: 60) + "end?"
        let text = QuestionForm.readable(input(q(long, options: opts(["A", "B"], descriptions: ["first choice", nil]), multi: true, header: "Pick")))
        XCTAssertEqual(text, "Pick\n\(long)\n(Choose any)\n• A — first choice\n• B")
        let malformed = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .notify,
                                   input: .object(["questions": .array([.object(["question": .string("Free text?")])])]))
        XCTAssertTrue(ConsentContext.make(malformed, session: nil).detail.contains("Free text?"))   // unparseable input is still shown, raw
    }

    func testQuestionConsentContextShowsQuestionsEvenWhenReadOnly() {
        let r = UI.request("Q", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .notify,
                           input: input(q("DB?", options: opts(["Mongo", "Postgres"]), header: "DB")))
        let c = ConsentContext.make(r, session: nil)
        XCTAssertEqual(c.detailLabel, "Question")
        XCTAssertEqual(c.detail, "DB\nDB?\n(Choose one)\n• Mongo\n• Postgres")
    }
}

final class HotkeyRepeatGateTests: XCTestCase {
    func testActsOnFirstPressOnlyUntilReleased() {
        var g = HotkeyRepeatGate()
        XCTAssertTrue(g.pressed(1))
        XCTAssertFalse(g.pressed(1)); XCTAssertFalse(g.pressed(1))   // auto-repeat
        XCTAssertTrue(g.pressed(2))                                  // other keys are independent
        g.released(1)
        XCTAssertTrue(g.pressed(1))
        g.reset()                                                    // re-registering must not leave a key stuck
        XCTAssertTrue(g.pressed(1)); XCTAssertTrue(g.pressed(2))
    }
}
