import XCTest
@testable import AgentDeckCore

final class CardLayoutTests: XCTestCase {
    func testButtonsPerRequestShape() {
        XCTAssertEqual(CardLayout.buttons(for: UI.request("a")), [.allow, .deny, .denyWithNote, .openInCursor])
        XCTAssertEqual(CardLayout.buttons(for: UI.request("a", personOnly: true)), [.deny, .approveInCursor])
        XCTAssertEqual(CardLayout.buttons(for: UI.request("a", hook: .notification, channel: .notify)), [.needsApprovalOpen, .dismiss])
        XCTAssertEqual(CardLayout.buttons(for: UI.request("a", tool: "ExitPlanMode", kind: .planReview, hook: .notification, channel: .notify)), [.reviewInCursor, .dismiss])   // B2: dismiss is not an approval
        XCTAssertEqual(CardLayout.buttons(for: UI.request("a", tool: "AskUserQuestion", kind: .question, hook: .preToolUse, channel: .gate)), [.answerInCursor, .dismiss])
    }
    func testNoButtonOffersAllowOnPersonOnlyOrNotice() {
        for r in [UI.request("a", personOnly: true), UI.request("b", channel: .notify)] { XCTAssertFalse(CardLayout.buttons(for: r).contains(.allow)) }
    }
    func testTitles() {
        XCTAssertEqual(CardButton.denyWithNote.title, "Deny + note…"); XCTAssertEqual(CardButton.openInCursor.title, "Open in Cursor ↗")
        XCTAssertEqual(CardButton.needsApprovalOpen.title, "needs approval · Open ↗"); XCTAssertEqual(CardButton.approveInCursor.title, "Approve in Cursor ↗")
    }
    func testHeadlineAndRisk() {
        XCTAssertEqual(CardFormat.displayTool("mcp__github__create_issue"), "github.create_issue")
        XCTAssertEqual(CardFormat.headline(UI.request("a", preview: "npm test")), "Bash  npm test")
        XCTAssertEqual(CardFormat.risk(Risk(level: .med, reason: "package install")), "MED · package install")
    }
    func testAllowAlwaysNeverOffersDenyAskOrRemovalSuggestions() {
        func sug(_ o: [String: JSONValue]) -> JSONValue { .object(o) }
        let allow = sug(["type": .string("addRules"), "behavior": .string("allow"), "rules": .array([.object(["toolName": .string("Bash")])])])
        let deny = sug(["type": .string("addRules"), "behavior": .string("deny"), "rules": .array([.object(["toolName": .string("Bash")])])])
        let ask = sug(["type": .string("addRules"), "behavior": .string("ask"), "rules": .array([.object(["toolName": .string("Bash")])])])
        let remove = sug(["type": .string("removeDirectories"), "directories": .array([.string("/w")])])
        let dirs = sug(["type": .string("addDirectories"), "directories": .array([.string("/w")])])
        let b = CardLayout.buttons(for: UI.request("a", suggestions: [allow, deny, ask, remove, dirs]))
        XCTAssertEqual(b.compactMap { if case .allowAlways(_, let s) = $0 { return s } else { return nil } }, [allow, dirs])
    }
    func testAllowNeedsHoldForHighRiskOrUnseenDetail() {
        XCTAssertFalse(CardLayout.allowNeedsHold(UI.request("a")))
        XCTAssertTrue(CardLayout.allowNeedsHold(UI.request("a", risk: .high)))
        let long = (1...12).map { "echo \($0)" }.joined(separator: "\n")
        XCTAssertTrue(CardLayout.allowNeedsHold(UI.request("a", input: .object(["command": .string(long)]))))
    }
}
