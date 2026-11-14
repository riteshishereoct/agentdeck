import XCTest
@testable import AgentDeckCore

final class DecisionAuditTests: XCTestCase {
    func testAuditCarriesKindSourceOutcomeButNeverNoteOrAnswerText() {
        let deny = Daemon.decisionAudit(stamp: "T", requestId: "r1", decision: .deny(note: "secret-note sk-123"), source: .click, result: .applied)
        XCTAssertEqual(deny, "T decision r1 kind=deny+note source=click result=applied")
        let ans = Daemon.decisionAudit(stamp: "T", requestId: "r2", decision: .answer(["Which?": "private answer"]), source: .click, result: .dropped(.unknownOrResolved))
        XCTAssertEqual(ans, "T decision r2 kind=answer(1) source=click result=dropped:unknownOrResolved")
        XCTAssertFalse(deny.contains("secret") || ans.contains("private"))
    }
}

final class HookDiedAuditTests: XCTestCase {
    func testLivenessReleaseLineIsMetadataOnly() {
        XCTAssertEqual(Daemon.hookDiedAudit(stamp: "T", requestId: "r9"), "T release r9 kind=hookDied result=handledElsewhere")
    }
}
