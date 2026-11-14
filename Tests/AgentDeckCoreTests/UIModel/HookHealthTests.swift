import XCTest
@testable import AgentDeckCore

final class HookHealthTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t.addingTimeInterval(s) }

    func testCleanChecksBackOffBoundedThenWaitWithoutATimer() {
        var h = HookHealth(); h.miss(now: t)
        XCTAssertEqual(h.state, .checking); XCTAssertEqual(h.nextCheckAt, t)
        var timers = 0, now = t
        while let next = h.nextCheckAt, timers < 10 { now = next; h.apply(.ok, now: now); timers += 1 }
        XCTAssertEqual(timers, HookHealth.backoff.count + 1, "check now, then 5 s, 30 s, 2 min, then stop")
        XCTAssertEqual(h.state, .checking); XCTAssertNil(h.nextCheckAt); XCTAssertTrue(h.degraded)
        XCTAssertEqual(h.explanation?.hasPrefix("Checks passed; waiting for the next tool call"), true)
        h.miss(now: at(500))                                                    // another tool ran without a hook after clean checks
        XCTAssertEqual(h.state, .actionRequired); XCTAssertEqual(h.cause, .sessionNotHooked); XCTAssertNil(h.nextCheckAt)
    }
    func testBackoffDelays() {
        var h = HookHealth(); h.miss(now: t)
        h.apply(.ok, now: t); XCTAssertEqual(h.nextCheckAt, at(5))
        h.apply(.reconnected, now: at(5)); XCTAssertEqual(h.state, .reconnecting); XCTAssertEqual(h.nextCheckAt, at(35))
        h.apply(.ok, now: at(35)); XCTAssertEqual(h.state, .checking); XCTAssertEqual(h.nextCheckAt, at(155))
    }
    func testRepeatedMissesDuringTheEpisodeEndInActionRequired() {
        var h = HookHealth(); h.miss(now: t); h.miss(now: at(1))
        for _ in 0...HookHealth.backoff.count { h.apply(.ok, now: h.nextCheckAt ?? t) }
        XCTAssertEqual(h.state, .actionRequired); XCTAssertEqual(h.cause, .sessionNotHooked); XCTAssertEqual(h.missed, 2)
    }
    func testActionFindingIsTerminalAndLateFindingsAreIgnored() {
        var h = HookHealth(); h.miss(now: t); h.apply(.action(.hooksNotRegistered), now: t)
        XCTAssertEqual(h.state, .actionRequired); XCTAssertNil(h.nextCheckAt); XCTAssertTrue(h.offersRepair)
        h.apply(.ok, now: at(5)); XCTAssertEqual(h.state, .actionRequired); XCTAssertNil(h.nextCheckAt)
        h.retry(now: at(9)); XCTAssertEqual(h.state, .checking); XCTAssertEqual(h.nextCheckAt, at(9)); XCTAssertNil(h.cause)
    }
    func testHealthyOrRecoveredOnlyFromAHook() {
        var h = HookHealth(); h.miss(now: t)
        for f in [HookHealth.Finding.ok, .reconnected, .ok, .ok, .ok] { h.apply(f, now: h.nextCheckAt ?? t); XCTAssertNotEqual(h.state, .healthy) }
        h.retry(now: at(1)); XCTAssertNotEqual(h.state, .healthy)
        h.hook(at: at(2)); XCTAssertEqual(h.state, .recovered); XCTAssertEqual(h.lastHookAt, at(2)); XCTAssertNil(h.nextCheckAt)
        h.retry(now: at(3)); XCTAssertEqual(h.state, .recovered, "retry never disturbs a recovered session")
        var fresh = HookHealth(); fresh.retry(now: t); XCTAssertEqual(fresh.state, .healthy); XCTAssertNil(fresh.nextCheckAt)
    }
    func testStaleHookCannotRecoverANewerMiss() {
        var h = HookHealth(); h.hook(at: t); h.miss(now: at(20))
        h.hook(at: at(10))
        XCTAssertEqual(h.state, .checking)
        XCTAssertEqual(h.missed, 1)
        h.hook(at: at(21)); XCTAssertEqual(h.state, .recovered)
    }
    func testTexts() {
        var h = HookHealth(); XCTAssertNil(h.badge); XCTAssertNil(h.explanation)
        h.miss(now: t)
        XCTAssertEqual(h.badge, "hooks: checking")
        XCTAssertEqual(h.explanation, "AgentDeck may miss approvals or steps for this session. Checking… 1 earlier step was not seen.")
        h.apply(.action(.extensionChanged("2.1.330")), now: t)
        XCTAssertEqual(h.explanation, "Claude Code updated to 2.1.330; restart the Claude tab to load hooks. 1 earlier step was not seen.")
        XCTAssertFalse(h.offersRepair); XCTAssertTrue(h.offersRetry)
        XCTAssertEqual(HookHealth.action(.hooksNotRegistered), "AgentDeck hooks are missing from ~/.claude/settings.json. Click Repair hooks.")
        var s = Session(id: "s", startedAt: t, lastEventAt: t); s.hookHealth = h; s.hooksDegraded = true
        XCTAssertEqual(RowDetail.degradedBadge(s), "hooks: action needed")
        XCTAssertEqual(RowDetail.hookHealthLine(s, timeZone: TimeZone(identifier: "UTC")!)?.hasSuffix("not seen. No hook seen yet."), true)
        s.hookHealth.hook(at: Date(timeIntervalSince1970: 1_800_009_720))   // 2027-01-15 10:42 UTC
        XCTAssertEqual(RowDetail.degradedBadge(s), "hooks recovered")
        XCTAssertEqual(RowDetail.hookHealthLine(s, timeZone: TimeZone(identifier: "UTC")!),
                       "Hooks are reaching AgentDeck again. 1 earlier step was not seen. Last hook 10:42.")
    }
}
