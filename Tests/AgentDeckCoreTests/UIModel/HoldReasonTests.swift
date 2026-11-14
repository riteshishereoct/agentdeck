import XCTest
@testable import AgentDeckCore

final class HoldReasonTests: XCTestCase {
    private func ctx(detail: String = "ls", incomplete: Bool = false) -> ConsentContext {
        ConsentContext(task: nil, what: "w", detailLabel: "Command", detail: detail, reason: "r", scope: "s", risk: "LOW", identity: "i", sessionTitle: nil, incomplete: incomplete)
    }
    func testHigh() { XCTAssertEqual(HoldReason.text(risk: .high, context: ctx(), broadRule: false), "High risk") }
    func testLong() { XCTAssertEqual(HoldReason.text(risk: .low, context: ctx(detail: String(repeating: "x", count: 501)), broadRule: false), "Long command: not all of it fits on the card") }
    func testIncomplete() { XCTAssertEqual(HoldReason.text(risk: .low, context: ctx(incomplete: true), broadRule: false), "Part of the request is not shown on the card") }
    func testBroad() { XCTAssertEqual(HoldReason.text(risk: .low, context: ctx(), broadRule: true), "Broad rule: lasts beyond this request") }
    func testDrops() {
        XCTAssertEqual(HoldReason.dropText(.staleCard), "Already resolved or expired")
        XCTAssertEqual(HoldReason.dropText(.notArmed), "Not ready: card was not fully visible")
        XCTAssertEqual(HoldReason.dropText(.needsHold), "Needs a hold")
    }
}
