import XCTest
import Darwin
@testable import AgentDeckCore

/// Review finding: a SIGKILLed hook's orphan curl kept /v1/wait open, so a card offered Allow for up to 590 s and reported
/// `applied` although nothing reached Claude. With X-Adeck-Hook-Pid the daemon releases it on the next tick.
final class HookLivenessTests: XCTestCase {
    var h: DaemonHarness!
    override func tearDown() { h?.stop() }
    // Daemon/ -> AgentDeckCoreTests/ -> Tests/ -> repo root
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func log() -> String { (try? String(contentsOf: h.paths.logFile, encoding: .utf8)) ?? "" }
    private func spawnSleep() -> pid_t {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, nil), 0)
        return pid
    }
    private func hold(session: String) -> String {
        var b = bashBody; b["session_id"] = session
        return String(h.post("/v1/decide/PermissionRequest", b).dropFirst(5))
    }
    private func wait(_ id: String, hookPid: pid_t?) throws -> TestUnixClient {
        let c = try TestUnixClient(path: h.paths.socket.path)
        c.send("GET /v1/wait/\(id) HTTP/1.1\r\nHost: adeck\r\n" + (hookPid.map { "X-Adeck-Hook-Pid: \($0)\r\n" } ?? "") + "\r\n")
        return c
    }

    func testWaitWithDeadHookPidIsReleasedWithinTwoTicksOnlyForThatSessionAndAudited() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let hookA = spawnSleep(), hookB = spawnSleep()
        defer { kill(hookB, SIGKILL); var st: Int32 = 0; waitpid(hookB, &st, 0) }
        let a = hold(session: "A"), b = hold(session: "B")
        let ca = try wait(a, hookPid: hookA), cb = try wait(b, hookPid: hookB)
        let old = try wait(hold(session: "C"), hookPid: nil)                        // an older hook: no pid, unchanged behaviour
        XCTAssertFalse(ca.read(for: 0.3).eof); XCTAssertTrue(h.updates.isEmpty)
        kill(hookA, SIGKILL)                                                        // left a zombie on purpose: still dead
        let killed = Date()
        XCTAssertTrue(h.waitUntil(1) { h.updates.map { $0.1 } == [.handledElsewhere] }, "got \(h.updates)")
        XCTAssertLessThan(Date().timeIntervalSince(killed), 0.5, "≤ 2 ticks of 100 ms plus scheduling")
        XCTAssertEqual(h.updates.first?.0, a)
        XCTAssertTrue(ca.read(for: 1).eof, "the orphan's wait is closed, so its curl ends")
        XCTAssertEqual(h.resolve(a, .allow), .dropped(.unknownOrResolved))       // late click
        var st: Int32 = 0; waitpid(hookA, &st, 0)
        XCTAssertTrue(log().contains("release \(a) kind=hookDied result=handledElsewhere"), log())
        XCTAssertTrue(log().contains("decision \(a) kind=allow source=click result=dropped:unknownOrResolved"))
        XCTAssertFalse(cb.read(for: 0.2).eof); XCTAssertFalse(old.read(for: 0.01).eof)
        XCTAssertEqual(h.resolve(b, .allow), .applied)                            // the live hook still works
        XCTAssertEqual(h.updates.map { $0.1 }, [.handledElsewhere, .allowed])
    }

    func testSigkilledRealHookResolvesHandledElsewhereAndALateAllowIsDropped() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let seen = PendingSeen(); h.daemon.onChange = { seen.add($0) }
        let tmp = h.home.appendingPathComponent("tmp"); try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [repo.appendingPathComponent("hooks/adeck-hook").path, "decide", "PermissionRequest"]
        p.environment = ["HOME": h.home.path, "PATH": "/usr/bin:/bin", "TMPDIR": tmp.path,
                         "__CFBundleIdentifier": cursor, "CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
        p.standardInput = try FileHandle(forReadingFrom: repo.appendingPathComponent("Tests/AgentDeckCoreTests/Fixtures/hooks/PermissionRequest-Bash.json"))
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); defer { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
        let end = Date().addingTimeInterval(5)
        while seen.pending.isEmpty && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let id = try XCTUnwrap(seen.pending.keys.first, "the hook never attached its wait")
        XCTAssertTrue(h.updates.isEmpty)
        kill(p.processIdentifier, SIGKILL)                                          // no trap runs
        let killed = Date()
        XCTAssertTrue(h.waitUntil(1) { h.updates.map { $0.1 } == [.handledElsewhere] }, "got \(h.updates)")
        XCTAssertLessThan(Date().timeIntervalSince(killed), 0.5)
        XCTAssertEqual(h.resolve(id, .allow), .dropped(.unknownOrResolved))
        XCTAssertEqual(h.updates.map { $0.1 }, [.handledElsewhere])
        XCTAssertTrue(h.waitUntil(3) { (try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.isEmpty == true },
                      "the hook's temp file is cleaned up after the SIGKILL")
    }
}
