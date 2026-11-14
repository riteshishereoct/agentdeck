import XCTest
@testable import AgentDeckCore

private final class CountingIdleClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; reads += 1; return Date() }
}

final class IdleDaemonTests: XCTestCase {
    func testIdleDaemonStopsPollingAndNewHookRestartsMaintenance() throws {
        let clock = CountingIdleClock()
        let h = try DaemonHarness(clock: clock)
        defer { h.stop() }
        let idleReads = clock.count
        let idle = expectation(description: "idle observation")
        h.daemon.queue.asyncAfter(deadline: .now() + 0.5) { idle.fulfill() }
        wait(for: [idle], timeout: 2)
        XCTAssertEqual(clock.count, idleReads, "Idle daemon must not wake on a polling timer")
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", bashBody), "PASS")
        let activeReads = clock.count
        let active = expectation(description: "active observation")
        h.daemon.queue.asyncAfter(deadline: .now() + 1.4) { active.fulfill() }   // 1 Hz without broker timed work (review H3)
        wait(for: [active], timeout: 2)
        XCTAssertGreaterThan(clock.count, activeReads, "New hook must restart maintenance for active work")
    }
    func testActiveSessionWithoutBrokerWorkTicksAtOneHertzNotTen() throws {   // review H3
        let clock = CountingIdleClock()
        let h = try DaemonHarness(clock: clock)
        defer { h.stop() }
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", bashBody), "PASS")      // Bash on .notify: active session, no timed work
        let start = clock.count
        let e = expectation(description: "observe"); h.daemon.queue.asyncAfter(deadline: .now() + 2.05) { e.fulfill() }
        wait(for: [e], timeout: 4)
        XCTAssertLessThanOrEqual(clock.count - start, 3, "about 2 ticks in 2 s, not 20")
        XCTAssertGreaterThanOrEqual(clock.count - start, 1)
    }
}
