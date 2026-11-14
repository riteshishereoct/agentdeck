import XCTest
@testable import AgentDeckCore

/// End to end over the real socket and the real transcript tailer, with a fake clock driving ticks.
final class HookHealthDaemonTests: XCTestCase {
    var h: DaemonHarness!
    let clock = FakeClock()
    private var last: [Session] = []
    override func tearDown() { h?.stop() }
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d) }
    private func health(_ id: String = "s1") -> HookHealth? { last.first { $0.id == id }?.hookHealth }
    private func spin(until timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return cond()
    }
    private func sync(_ f: @escaping () -> Void) { h.daemon.queue.sync(execute: f) }

    /// A session whose transcript shows one tool that ran with no PreToolUse.
    private func startWithMiss(hooked: Bool = false) throws {
        h = try DaemonHarness(clock: clock)
        h.daemon.onChange = { [weak self] in self?.last = $0 }
        if hooked { try writeSettings(); try installScript() }   // before the miss: the first check runs at once
        let t = h.home.appendingPathComponent("s1.jsonl")
        let t0 = clock.now()
        let lines = [
            #"{"type":"assistant","timestamp":"\#(iso(t0.addingTimeInterval(1)))","message":{"content":[{"type":"tool_use","id":"toolu_miss","name":"Bash","input":{}}]}}"#,
            #"{"type":"user","timestamp":"\#(iso(t0.addingTimeInterval(2)))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_miss","content":"ok"}]}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: t, atomically: true, encoding: .utf8)
        h.post("/v1/event/SessionStart", ["session_id": "s1", "cwd": "/p", "transcript_path": t.path])
        sync { self.h.daemon.tickNow() }                                   // the tailer reads both lines
        sync { self.clock.advance(10); self.h.daemon.tickNow() }           // 8 s after the result: a miss
    }
    private func writeSettings(foreign: Bool = false) throws {
        var hooks: [String: Any] = [:]
        for ev in HookDiagnostics.events { hooks[ev] = [["hooks": [["type": "command", "command": "~/.agentdeck/bin/adeck-hook event \(ev)"]]]] }
        if foreign { hooks["Stop"] = (hooks["Stop"] as! [Any]) + [["hooks": [["type": "command", "command": "say done"]]]] }
        let url = HookDiagnostics.settings(home: h.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["hooks": hooks, "model": "x"]).write(to: url)
    }
    private func installScript() throws {
        let url = HookDiagnostics.hookScript(home: h.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repo.appendingPathComponent("hooks/adeck-hook"), to: url)
        chmod(url.path, 0o755)
    }
    private func log() -> String { (try? String(contentsOf: h.paths.logFile, encoding: .utf8)) ?? "" }

    func testMissingRegistrationIsActionRequiredWithRepairAndNoTimerOrRequest() throws {
        try startWithMiss()
        XCTAssertTrue(spin { self.health()?.state == .actionRequired }, "\(String(describing: health()))")
        XCTAssertEqual(health()?.cause, .hooksNotRegistered); XCTAssertTrue(health()?.offersRepair == true)
        XCTAssertTrue(log().contains("health session=s1 finding=action:hooksNotRegistered"))
        var timers = -1; sync { timers = self.h.daemon.pendingHealthChecks }; XCTAssertEqual(timers, 0, "no timer after a terminal state")
        XCTAssertTrue(h.updates.isEmpty); XCTAssertTrue(last.allSatisfy { $0.pending.isEmpty })
    }

    func testCleanChecksWaitForEvidenceAndOnlyAFreshPreToolUseRecovers() throws {
        try startWithMiss(hooked: true)
        XCTAssertTrue(spin { self.health()?.state == .checking && self.health()?.nextCheckAt != nil })
        XCTAssertEqual(health()?.nextCheckAt, clock.now().addingTimeInterval(5))
        var timers = 0; sync { timers = self.h.daemon.pendingHealthChecks }; XCTAssertEqual(timers, 1)
        var b = bashBody; b["tool_use_id"] = "toolu_next"
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", b), "PASS")
        XCTAssertTrue(spin { self.health()?.state == .recovered })
        XCTAssertEqual(health()?.missed, 1); XCTAssertEqual(health()?.lastHookAt, clock.now())
        sync { timers = self.h.daemon.pendingHealthChecks }; XCTAssertEqual(timers, 0)
    }

    func testExtensionChangeAndDeadListenerAreDiagnosed() throws {
        try startWithMiss(hooked: true)
        XCTAssertTrue(spin { self.health()?.nextCheckAt != nil })
        // Our listener vanished (socket file removed): the check re-listens; the hooks reach us again.
        unlink(h.paths.socket.path)
        h.daemon.checkHookHealth(sessionId: "s1")
        XCTAssertTrue(spin { self.health()?.state == .reconnecting }, "\(String(describing: health()))")
        XCTAssertEqual(h.code(["-X", "POST", "--data-binary", "{}", "http://adeck/v1/event/Stop"]), "204")
        try JSONSerialization.data(withJSONObject: ["version": 1, "extensionVersion": "2.1.323", "categories": [:]]).write(to: h.paths.capabilities)
        sync { self.h.daemon.runningVersion = { _ in "2.1.330" } }
        h.daemon.checkHookHealth(sessionId: "s1")
        XCTAssertTrue(spin { self.health()?.cause == .extensionChanged("2.1.330") })
        XCTAssertEqual(health()?.state, .actionRequired); XCTAssertEqual(health()?.offersRepair, false)
    }

    func testFailedListenerRecoveryIsActionRequiredNotChecksPassed() throws {
        try startWithMiss(hooked: true)
        XCTAssertTrue(spin { self.health()?.nextCheckAt != nil })
        unlink(h.paths.socket.path)
        try Data("occupied".utf8).write(to: h.paths.socket)
        h.daemon.checkHookHealth(sessionId: "s1")
        XCTAssertTrue(spin { self.health()?.cause == .listenerUnavailable })
        XCTAssertEqual(health()?.state, .actionRequired)
        XCTAssertNil(health()?.nextCheckAt)
        XCTAssertTrue(health()?.offersRetry == true)
        XCTAssertFalse(health()?.offersRepair == true)
        XCTAssertEqual(try Data(contentsOf: h.paths.socket), Data("occupied".utf8), "never overwrite an unrelated file")
    }

    func testRepairRunsTheInstallerOnlyOnRequestKeepsForeignSettingsAndNeverMarksHealthy() throws {
        try startWithMiss()
        XCTAssertTrue(spin { self.health()?.cause == .hooksNotRegistered })
        try writeSettings(foreign: true)
        let settings = HookDiagnostics.settings(home: h.home)
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var hooks = root["hooks"] as! [String: Any]; hooks["PreToolUse"] = nil; root["hooks"] = hooks   // registration broken
        try JSONSerialization.data(withJSONObject: root).write(to: settings)
        h.daemon.hookSource = repo
        let done = expectation(description: "repair"); var ok = false
        h.daemon.repairHooks { ok = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertTrue(ok)
        XCTAssertTrue(HookDiagnostics.registered(settings: settings))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        XCTAssertEqual(after["model"] as? String, "x")
        XCTAssertTrue(String(decoding: try JSONSerialization.data(withJSONObject: after), as: UTF8.self).contains("say done"), "foreign hook kept")
        XCTAssertNil(HookDiagnostics.scriptProblem(at: HookDiagnostics.hookScript(home: h.home), bundled: repo.appendingPathComponent("hooks/adeck-hook")))
        XCTAssertTrue(spin { self.health()?.state == .checking })
        XCTAssertNotEqual(health()?.state, .healthy, "repair proves nothing until a PreToolUse arrives")
        XCTAssertTrue(h.updates.isEmpty)
    }

    func testRepairWithoutAKnownSourceIsRefused() throws {
        h = try DaemonHarness(clock: clock)
        let done = expectation(description: "repair"); var ok = true
        h.daemon.repairHooks { ok = $0; done.fulfill() }
        wait(for: [done], timeout: 2); XCTAssertFalse(ok)
    }

    func testMissingPythonStopsRepairBeforeHookOrSettingsChangesAndExplainsRecovery() throws {
        h = try DaemonHarness(clock: clock, start: false)
        h.daemon.hookSource = repo
        h.daemon.repairPythonExecutable = h.home.appendingPathComponent("no-python")
        let done = expectation(description: "missing Python"); var ok = true
        h.daemon.repairHooks { ok = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(ok)
        XCTAssertTrue(h.daemon.hookRepairError?.contains("/usr/bin/python3") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookDiagnostics.settings(home: h.home).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: HookDiagnostics.hookScript(home: h.home).path))
    }

    func testBrokenPythonIsRejectedAndSystemPythonParsesJSON() {
        XCTAssertFalse(Daemon.repairPythonAvailable(at: URL(fileURLWithPath: "/usr/bin/false")))
        XCTAssertTrue(Daemon.repairPythonAvailable())
    }

    func testInstallerFailureKeepsInvalidSettingsAndReportsRecovery() throws {
        h = try DaemonHarness(clock: clock, start: false)
        h.daemon.hookSource = repo
        let settings = HookDiagnostics.settings(home: h.home)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("invalid JSON".utf8)
        try original.write(to: settings)
        let done = expectation(description: "installer failure"); var ok = true
        h.daemon.repairHooks { ok = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertFalse(ok)
        XCTAssertEqual(try Data(contentsOf: settings), original)
        XCTAssertTrue(h.daemon.hookRepairError?.contains("valid JSON") == true)
    }

    func testDiagnosticsParsing() {
        XCTAssertEqual(HookDiagnostics.version(inPath: "/Users/u/.cursor/extensions/anthropic.claude-code-2.1.323-darwin-arm64/resources/native-binary/claude"), "2.1.323")
        XCTAssertNil(HookDiagnostics.version(inPath: "/opt/homebrew/bin/node"))
        XCTAssertEqual(Daemon.healthAudit(stamp: "T", sessionId: "s1", finding: .action(.extensionChanged("9"))), "T health session=s1 finding=action:extensionChanged")
    }
}
