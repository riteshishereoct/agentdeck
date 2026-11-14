import XCTest
@testable import AgentDeckCore

final class GoalLabelTests: XCTestCase {
    private func goal(_ s: String) -> String? { SessionLabels.goal(s) }

    func testIdeWrapperBlocksAreRemovedWholeNotJustTags() {
        let raw = "<ide_opened_file>The user opened the file /Users/me/a.ts in the IDE.</ide_opened_file>\n<ide_selection>const x = 1;</ide_selection>\n<system-reminder>Be careful.</system-reminder>\nFix the login redirect loop"
        XCTAssertEqual(goal(raw), "Fix the login redirect loop")
    }
    func testWrapperOnlyPromptHasNoGoal() {
        XCTAssertNil(goal("<ide_opened_file>opened /a/b.ts</ide_opened_file>"))
        XCTAssertNil(goal("<system-reminder>x</system-reminder>\n<local-command-stdout>ok</local-command-stdout>  "))
        XCTAssertNil(goal("<local-command-stderr>boom</local-command-stderr>"))
        XCTAssertNil(goal("   \n "))
    }
    func testUnclosedWrapperFromTruncatedPreviewIsDroppedToTheEnd() {
        XCTAssertNil(goal("<system-reminder>This got cut off by the preview limit and never closes"))
        XCTAssertEqual(goal("Real ask <ide_selection>half a selection"), "Real ask")
    }
    func testSlashCommandBecomesNameAndArgs() {
        XCTAssertEqual(goal("<command-message>review is running…</command-message>\n<command-name>/review</command-name>\n<command-args>PR 42 please</command-args>"), "/review PR 42 please")
        XCTAssertEqual(goal("<command-name>/clear</command-name><command-args></command-args>"), "/clear")
        XCTAssertEqual(goal("<command-name>/compact</command-name>"), "/compact")
    }
    func testPastedContentDroppedWhenOtherTextRemainsElseItsFirstLineIsUsed() {
        XCTAssertEqual(goal("Summarise this log <pasted_content id=\"a\">\nline1\nline2\n</pasted_content>"), "Summarise this log")
        XCTAssertEqual(goal("<pasted_content id=\"a\">\n\n  Build the hover overlay\nmore\n</pasted_content>"), "Build the hover overlay")
        XCTAssertNil(goal("<pasted_content id=\"x\">"))
    }
    func testWhitespaceCollapsesAndFirstSentenceWins() {
        XCTAssertEqual(goal("\n\n  Fix   the\t parser.  Then add tests and docs.\nmore detail"), "Fix the parser.")
        XCTAssertEqual(goal("Fix the S3 pool leak\nplease"), "Fix the S3 pool leak")   // later lines are detail
        XCTAssertEqual(goal("Does v1.2 work? Check it."), "Does v1.2 work?")
        XCTAssertEqual(goal("1. Fix the bug\n2. Add tests"), "1. Fix the bug")
        XCTAssertEqual(goal("Step 1. Fix the bug"), "Step 1. Fix the bug")   // list numbers are not sentence ends
        XCTAssertEqual(goal("# Build AgentDeck\nmore"), "Build AgentDeck")
        XCTAssertEqual(goal("claude-opus-5-5"), "claude-opus-5-5")
    }
    func testLongPromptCapsAt90OnAWordBoundaryWithEllipsis() throws {
        let long = (1...40).map { "word\($0)" }.joined(separator: " ")
        let g = try XCTUnwrap(goal(long))
        XCTAssertLessThanOrEqual(g.count, 90); XCTAssertTrue(g.hasSuffix("…"))
        XCTAssertTrue(long.hasPrefix(String(g.dropLast())), "prefix of the original")
        XCTAssertTrue(g.dropLast().split(separator: " ").allSatisfy { $0.hasPrefix("word") && Int($0.dropFirst(4)) != nil }, "no cut word: \(g)")
        XCTAssertEqual(try XCTUnwrap(goal(String(repeating: "x", count: 300))).count, 90)   // no space to break on
    }
    func testFiveKilobytePromptIsBoundedAndReadable() throws {
        let raw = "<ide_opened_file>/a.ts</ide_opened_file>Refactor the session store so that restore never replays work " + String(repeating: "and keep going ", count: 350)
        XCTAssertGreaterThan(raw.utf8.count, 5000)
        let g = try XCTUnwrap(goal(raw))
        XCTAssertLessThanOrEqual(g.count, 90); XCTAssertTrue(g.hasPrefix("Refactor the session store")); XCTAssertTrue(g.hasSuffix("…"))
    }
    func testUnicodeAndEmojiNeverSplit() throws {
        let fam = "👨‍👩‍👧‍👦"
        let g = try XCTUnwrap(goal(String(repeating: fam + " ", count: 60)))
        XCTAssertLessThanOrEqual(g.count, 90)
        XCTAssertTrue(g.dropLast().split(separator: " ").allSatisfy { $0 == Substring(fam) })
        XCTAssertEqual(goal("修复登录问题。然后加测试"), "修复登录问题。")
        XCTAssertEqual(goal("Café über naïve"), "Café über naïve")
    }
    func testSecretsAreMaskedBeforeTruncation() throws {
        let secret = "AKIA" + "ABCDEFGHIJKLMNOP"
        let g = try XCTUnwrap(goal(String(repeating: "a ", count: 38) + "key " + secret + " tail"))   // secret straddles the 90-char cut
        XCTAssertFalse(g.contains("AKIA" + "ABC")); XCTAssertFalse(g.contains(secret))
        let short = try XCTUnwrap(goal("use " + secret))
        XCTAssertFalse(short.contains("ABCDEFGH")); XCTAssertTrue(short.contains("AKIA••••"))
    }

    func testRowTitlePriorityAiTitleThenGoalThenLatestAskThenUnavailable() {
        var s = UI.session(project: "my-project", title: "Fix S3 pool leak", goal: "<ide_opened_file>x</ide_opened_file>Do the other thing")
        XCTAssertEqual(RowFormat.title(s), "my-project · Fix S3 pool leak")
        s.title = nil; XCTAssertEqual(RowFormat.title(s), "my-project · Do the other thing")
        s.goal = "<system-reminder>only wrapper</system-reminder>"; s.latestAsk = "Follow up on tests"
        XCTAssertEqual(RowFormat.title(s), "my-project · Follow up on tests")
        s.latestAsk = nil; XCTAssertEqual(RowFormat.title(s), "my-project · Goal unavailable")
        s.project = ""; XCTAssertEqual(RowFormat.title(s), "unknown project · Goal unavailable")
    }
    func testRowTitleCapsLongAiTitleAndCleansIt() {
        let t = RowFormat.title(UI.session(project: "p", title: "  " + String(repeating: "Investigate flaky ", count: 10) + "  "))
        XCTAssertLessThanOrEqual(t.count, "p · ".count + 90); XCTAssertTrue(t.hasSuffix("…"))
    }
}
