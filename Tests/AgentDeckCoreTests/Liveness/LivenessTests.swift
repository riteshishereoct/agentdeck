import XCTest
@testable import AgentDeckCore

final class LivenessTests: XCTestCase {
    private typealias Info = (ppid: Int32, name: String)
    func testWalksUpToTheFirstClaudeOrNode() {
        let chain: [Int32: Info] = [100: (90, "sh"), 90: (80, "claude"), 80: (1, "zsh")]
        XCTAssertEqual(Liveness.resolveClaudePid(100, lookup: { chain[$0] }), 90)
        let node: [Int32: Info] = [100: (90, "sh"), 90: (80, "node")]
        XCTAssertEqual(Liveness.resolveClaudePid(100, lookup: { node[$0] }), 90)
        XCTAssertEqual(Liveness.resolveClaudePid(90, lookup: { chain[$0] }), 90)   // the pid itself already matches
    }
    // Amendment A1: an unverifiable pid is nil (unknown), never returned as-is and never treated as dead.
    func testNoMatchOrUnknownProcessReturnsNil() {
        let chain: [Int32: Info] = [100: (90, "sh"), 90: (80, "zsh"), 80: (1, "launchd")]
        XCTAssertNil(Liveness.resolveClaudePid(100, lookup: { chain[$0] }))
        XCTAssertNil(Liveness.resolveClaudePid(555, lookup: { _ in nil }))
    }
    func testWalkExaminesThePidPlusAtMostFiveParents() {
        var five: [Int32: Info] = [:]; for i in Int32(10)..<15 { five[i] = (i + 1, "sh") }; five[15] = (16, "claude")   // 5th parent
        XCTAssertEqual(Liveness.resolveClaudePid(10, lookup: { five[$0] }), 15)
        var six = five; six[15] = (16, "sh"); six[16] = (17, "claude")   // 6th parent: out of reach
        XCTAssertNil(Liveness.resolveClaudePid(10, lookup: { six[$0] }))
    }
    func testProcessInfoReadsTheRealProcessTable() {
        let me = Liveness.processInfo(getpid()); XCTAssertEqual(me?.ppid, getppid()); XCTAssertFalse(me?.name.isEmpty ?? true)
        XCTAssertNil(Liveness.processInfo(Int32.max))
    }
    func testIsAlive() throws {
        XCTAssertTrue(Liveness.isAlive(getpid()))
        XCTAssertTrue(Liveness.isAlive(1))   // launchd: kill(…, 0) gives EPERM, which still means alive
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try p.run(); p.waitUntilExit()
        XCTAssertFalse(Liveness.isAlive(p.processIdentifier))
        XCTAssertEqual(Liveness.checkInterval, 30)
    }
}
