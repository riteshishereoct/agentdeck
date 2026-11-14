import XCTest
@testable import AgentDeckCore

/// Build doc §4 "disconnect while held", end to end: the real hooks/adeck-hook against the real Daemon.
final class HookKilledWhileHeldTests: XCTestCase {
    var h: DaemonHarness!
    override func tearDown() { h?.stop() }
    // Failure/ -> AgentDeckCoreTests/ -> Tests/ -> repo root
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testKillingTheRealHookWhileHeldMeansHandledElsewhereAndALateClickIsDropped() throws {
        h = try DaemonHarness(categories: ["Bash": 1])
        let seen = PendingSeen(); h.daemon.onChange = { seen.add($0) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [repo.appendingPathComponent("hooks/adeck-hook").path, "decide", "PermissionRequest"]
        p.environment = ["HOME": h.home.path, "PATH": "/usr/bin:/bin", "TMPDIR": h.home.path,
                         "__CFBundleIdentifier": cursor, "CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]
        p.standardInput = try FileHandle(forReadingFrom: repo.appendingPathComponent("Tests/AgentDeckCoreTests/Fixtures/hooks/PermissionRequest-Bash.json"))
        p.standardOutput = Pipe(); p.standardError = FileHandle.nullDevice
        try p.run(); defer { if p.isRunning { p.kill() } }
        let end = Date().addingTimeInterval(5)
        while seen.pending.isEmpty && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let id = try XCTUnwrap(seen.pending.keys.first, "the hook never attached its wait")
        XCTAssertTrue(p.isRunning, "hook blocks while held")
        p.terminate()                                                   // Cursor answered and killed the hook
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertTrue((p.standardOutput as! Pipe).fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertTrue(h.waitUntil(3) { h.updates.map { $0.1 } == [.handledElsewhere] }, "got \(h.updates.map { $0.1 })")
        XCTAssertEqual(h.resolve(id, .allow), .dropped(.unknownOrResolved))   // late click
        XCTAssertEqual(h.updates.map { $0.1 }, [.handledElsewhere])
    }
}
private extension Process { func kill() { Darwin.kill(processIdentifier, SIGKILL) } }
