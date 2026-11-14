import XCTest
@testable import AgentDeckCore

final class DaemonLifecycleTests: XCTestCase {
    var h: DaemonHarness!
    override func tearDown() { h?.stop() }
    final class Changes { var calls = 0; var last: [Session] = [] }      // written and read on main only
    func watch(_ h: DaemonHarness) -> Changes {
        let c = Changes()
        h.daemon.onChange = { s in XCTAssertTrue(Thread.isMainThread); c.calls += 1; c.last = s }
        return c
    }
    func spin(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }   // lets main-queue deliveries run
    func spin(until timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { spin(0.02) }
        return cond()
    }

    func testHundredMsTickDropsAnUnwaitedHoldAsHookGone() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        XCTAssertTrue(h.post("/v1/decide/PermissionRequest", bashBody).hasPrefix("HOLD "))
        XCTAssertTrue(h.waitUntil(3) { h.updates.map { $0.1 } == [.hookGone] })
    }
    func testTimeoutReleaseAt590SecondsViaFakeClock() throws {
        let clock = FakeClock()
        h = try DaemonHarness(categories: ["Bash": 1], clock: clock)
        let id = String(h.post("/v1/decide/PermissionRequest", bashBody).dropFirst(5))
        let wait = h.launchCurl(["-m", "20", "http://adeck/v1/wait/\(id)"])
        let d = h.daemon
        usleep(400_000)                                                    // attached, heartbeating
        clock.advance(589); d.queue.sync { d.tickNow() }
        usleep(200_000); XCTAssertTrue(wait.isRunning, "still held at 589 s"); XCTAssertTrue(h.updates.isEmpty)
        clock.advance(1); d.queue.sync { d.tickNow() }
        let out = DaemonHarness.output(wait)                               // curl exits because the daemon closed: a release
        XCTAssertFalse(String(decoding: out, as: UTF8.self).contains("{"), "release carries no decision")
        XCTAssertEqual(Set(String(decoding: out, as: UTF8.self)), [" "])
        XCTAssertEqual(h.updates.map { $0.1 }, [.timedOut])
        XCTAssertEqual(h.resolve(id, .allow), .dropped(.unknownOrResolved))
    }
    func testOnChangeOnMainCoalescedAndSnapshotSavedAndRestoredLosslessly() throws {
        h = try DaemonHarness(start: false)
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let transcript = h.home.appendingPathComponent("old.jsonl")             // the goal is re-read from here, never from the snapshot
        try #"{"type":"user","message":{"content":"ship it"}}"#.write(to: transcript, atomically: true, encoding: .utf8)
        try SnapshotIO.save([Session(id: "old", project: "p", cwd: "/p", transcriptPath: transcript.path, goal: "ship it", state: .working, stepCount: 0, failureStreak: 0,
                                     hooksDegraded: false, startedAt: t, lastEventAt: t)], to: h.paths.snapshot)
        let c = watch(h)
        try h.daemon.start(); spin(0.3)
        let old = c.last.first { $0.id == "old" }
        XCTAssertEqual(old?.state, .idle)                                                          // loaded sessions start idle
        XCTAssertEqual(old?.goal, "ship it"); XCTAssertEqual(old?.startedAt, t)                    // restore, not a SessionStart replay
        c.calls = 0
        let harness = h!
        DispatchQueue.global().async { for i in 0..<20 { harness.post("/v1/event/SessionStart", ["session_id": "n\(i)", "cwd": "/p"]) } }
        spin(1.5)
        XCTAssertGreaterThanOrEqual(c.calls, 1); XCTAssertLessThan(c.calls, 20)                     // coalesced ≤ every 50 ms
        XCTAssertTrue(SnapshotIO.load(from: h.paths.snapshot).contains { $0.id == "n19" })
    }
    func testLivenessEndsOnlyVerifiedPidsThatDied() throws {                                       // amendment A1
        h = try DaemonHarness(start: false); let c = watch(h)
        let node = Process(); node.executableURL = URL(fileURLWithPath: "/bin/sleep"); node.arguments = ["60"]; try node.run()
        defer { if node.isRunning { node.terminate() } }
        // The real walk would climb from `sleep` to this machine's actual claude/node ancestors, so stand in for a verified pid.
        let standIn = node.processIdentifier
        h.daemon.resolvePid = { $0 == standIn ? $0 : Liveness.resolveClaudePid($0) }
        try h.daemon.start()
        let gone = Process(); gone.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try gone.run(); gone.waitUntilExit()
        h.post("/v1/event/SessionStart", ["session_id": "live", "cwd": "/p"], headers: ["X-Adeck-Pid: \(node.processIdentifier)"])
        h.post("/v1/event/SessionStart", ["session_id": "unknown", "cwd": "/p"], headers: ["X-Adeck-Pid: 1"])               // launchd: not claude/node
        h.post("/v1/event/SessionStart", ["session_id": "stale", "cwd": "/p"], headers: ["X-Adeck-Pid: \(gone.processIdentifier)"])
        XCTAssertTrue(spin { c.last.count == 3 })
        XCTAssertEqual(c.last.first { $0.id == "live" }?.pid, node.processIdentifier)
        XCTAssertNil(c.last.first { $0.id == "unknown" }?.pid); XCTAssertNil(c.last.first { $0.id == "stale" }?.pid)
        let d = h.daemon
        d.queue.sync { d.checkLiveness() }; spin(0.3)
        XCTAssertNotEqual(c.last.first { $0.id == "live" }?.state, .ended, "alive pid stays")
        node.terminate(); node.waitUntilExit()
        d.queue.sync { d.checkLiveness() }; spin(0.3)
        XCTAssertEqual(c.last.first { $0.id == "live" }?.state, .ended)
        XCTAssertNotEqual(c.last.first { $0.id == "unknown" }?.state, .ended, "nil pid never yields pidGone")
        XCTAssertNotEqual(c.last.first { $0.id == "stale" }?.state, .ended)
    }
    func testSettingsPresenceAndMatrixReload() throws {
        h = try DaemonHarness()
        XCTAssertEqual(h.post("/v1/decide/PermissionRequest", bashBody), "PASS")                   // Bash .notify
        try DaemonHarness.writeMatrix(["Bash": 1], to: h.paths.capabilities); h.daemon.reloadMatrix()
        XCTAssertEqual(h.daemon.matrix.channel(forTool: "Bash"), .race)
        XCTAssertTrue(h.post("/v1/decide/PermissionRequest", bashBody).hasPrefix("HOLD "))
        var paused = AppSettings(); paused.paused = true; h.daemon.update(settings: paused)
        XCTAssertEqual(h.post("/v1/decide/PermissionRequest", bashBody), "PASS")
        h.daemon.update(settings: AppSettings())
        try DaemonHarness.writeMatrix(["Bash": 2], to: h.paths.capabilities); h.daemon.reloadMatrix()
        h.daemon.update(presence: PresenceSnapshot(frontmostBundleId: cursor, idleSeconds: 0, at: Date()))
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", bashBody), "PASS")
        h.daemon.update(presence: PresenceSnapshot(frontmostBundleId: "com.google.Chrome", idleSeconds: 0, at: Date()))
        XCTAssertTrue(h.post("/v1/gate/PreToolUse", bashBody).hasPrefix("HOLD "))
    }
    func testLogHoldsMetadataOnly() throws {
        h = try DaemonHarness()
        h.post("/v1/gate/PreToolUse", ["session_id": "s-log", "cwd": "/p", "tool_name": "Bash", "tool_input": ["command": "echo SECRET-XYZ"]])
        XCTAssertTrue(h.waitUntil { ((try? String(contentsOf: h.paths.logFile)) ?? "").contains("s-log") })
        XCTAssertFalse(try String(contentsOf: h.paths.logFile).contains("SECRET-XYZ"))
    }
}
