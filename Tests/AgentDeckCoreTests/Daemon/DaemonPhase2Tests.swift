import XCTest
@testable import AgentDeckCore

final class DaemonPhase2Tests: XCTestCase {
    final class FakeRunner: SummarizerRunner {
        private let lock = NSLock(); private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func run(prompt: String, completion: @escaping (String?) -> Void) { lock.lock(); n += 1; lock.unlock(); completion("Fixing the pool leak") }
    }
    func testTranscriptToolResultResolvesTheHeldRequest() throws {
        let h = try DaemonHarness(categories: ["Bash": 1]); defer { h.stop() }
        let t = h.home.appendingPathComponent("t.jsonl"); FileManager.default.createFile(atPath: t.path, contents: Data())
        var b = bashBody; b["transcript_path"] = t.path; b["tool_use_id"] = "toolu_T1"
        XCTAssertEqual(h.post("/v1/gate/PreToolUse", b), "PASS")          // Channel 1: records correlation, starts tailing
        b["tool_use_id"] = nil
        let id = String(h.post("/v1/decide/PermissionRequest", b).dropFirst(5))
        let wait = h.launchCurl(["-m", "10", "http://adeck/v1/wait/\(id)"]); usleep(300_000)
        let line = #"{"type":"user","sessionId":"s1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_T1","content":"ok","is_error":false}]}}"# + "\n"
        let fh = try FileHandle(forWritingTo: t); fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try fh.close()
        XCTAssertTrue(h.waitUntil(3) { h.updates.map { $0.1 } == [.handledElsewhere] })
        XCTAssertFalse(String(decoding: DaemonHarness.output(wait), as: UTF8.self).contains("{"))   // released, no decision
    }
    func testSummarizerRunsOnStopOnlyWhenEnabled() throws {
        let h = try DaemonHarness(start: false); defer { h.stop() }
        let runner = FakeRunner(); h.daemon.summarizerRunner = runner; try h.daemon.start()
        let stop: [String: Any] = ["session_id": "s1", "cwd": "/p", "last_assistant_message": "Done."]
        h.post("/v1/event/Stop", stop); usleep(300_000)
        XCTAssertEqual(runner.count, 0)                                   // off by default (spec §10.1)
        var s = AppSettings(); s.summarizer = true; h.daemon.update(settings: s)
        h.post("/v1/event/Stop", stop)
        XCTAssertTrue(h.waitUntil { runner.count == 1 })
    }
    // plan-validation B3 (enabled from settings at start) and build-doc resolution (title only while none exists).
    func testSummarizerEnabledAtStartWritesTitleOnlyWhileNoneExists() throws {
        var settings = AppSettings(); settings.summarizer = true
        let h = try DaemonHarness(settings: settings, start: false); defer { h.stop() }
        let runner = FakeRunner(); h.daemon.summarizerRunner = runner
        var latest: [Session] = []; h.daemon.onChange = { latest = $0 }
        try h.daemon.start()
        func title(_ id: String) -> String? { latest.first { $0.id == id }?.title }
        func pump(_ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(3)
            while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return cond()
        }
        h.post("/v1/event/Stop", ["session_id": "s1", "cwd": "/p"])
        XCTAssertTrue(pump { title("s1") == "Fixing the pool leak" })
        let t = h.home.appendingPathComponent("t2.jsonl")
        try Data(#"{"type":"summary","summary":"Fix S3 pool leak","leafUuid":"u-1"}"#.utf8 + [10]).write(to: t)
        h.post("/v1/event/UserPromptSubmit", ["session_id": "s2", "cwd": "/p", "prompt": "go", "transcript_path": t.path])
        XCTAssertTrue(pump { title("s2") == "Fix S3 pool leak" })
        h.post("/v1/event/Stop", ["session_id": "s2", "cwd": "/p"])
        XCTAssertTrue(h.waitUntil { runner.count == 2 })
        XCTAssertFalse(pump { title("s2") != "Fix S3 pool leak" })        // the transcript title is never overwritten
    }
}
