import XCTest
@testable import AgentDeckCore

final class SnapshotIOTests: XCTestCase {
    private var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("adk-snap-\(UUID().uuidString.prefix(8))/sessions.json") }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    private func full() -> Session {
        Session(id: "s1", project: "proj", cwd: "/Users/me/proj", transcriptPath: "/tmp/t.jsonl", pid: 77, host: "h", entrypoint: "claude-vscode",
                title: "T", goal: "PROMPT-EXCERPT", latestAsk: "ASK", model: "claude-opus-5-5", state: .working,
                currentStep: Step(label: "Bash: echo SECRET-STEP", tool: "Bash", startedAt: Make.t0), stepCount: 9, summary: "SUMMARY",
                pending: [Make.request("r1")], startedAt: Make.t0, lastEventAt: Make.t(60))
    }
    func testRoundTripKeepsMetadataOnlyAndStartsIdle() throws {
        try SnapshotIO.save([full()], to: url)
        let back = SnapshotIO.load(from: url)
        XCTAssertEqual(back.count, 1); let s = back[0]
        XCTAssertEqual([s.id, s.project, s.cwd, s.transcriptPath, s.host, s.entrypoint, s.title, s.model],
                       ["s1", "proj", "/Users/me/proj", "/tmp/t.jsonl", "h", "claude-vscode", "T", "claude-opus-5-5"])
        XCTAssertNil(s.goal, "no transcript at /tmp/t.jsonl: the goal is not restored from the snapshot")
        XCTAssertEqual(s.pid, 77); XCTAssertEqual(s.startedAt, Make.t0); XCTAssertEqual(s.lastEventAt, Make.t(60))
        XCTAssertEqual(s.state, .idle); XCTAssertTrue(s.pending.isEmpty); XCTAssertNil(s.currentStep); XCTAssertEqual(s.stepCount, 0)
        XCTAssertNil(s.latestAsk); XCTAssertNil(s.summary)
    }
    func testFileHasNoPreviewsPendingOrStepsAndIsMode0600() throws {
        try SnapshotIO.save([full()], to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["SECRET-STEP", "npm test", "SUMMARY", "ASK", "pending", "fullInput", "\"goal\"", "PROMPT-EXCERPT"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let keys = Set((obj["sessions"] as! [[String: Any]])[0].keys)
        XCTAssertEqual(keys, ["id", "project", "cwd", "transcriptPath", "pid", "host", "entrypoint", "title", "model", "startedAt", "lastEventAt"])
        var st = stat(); XCTAssertEqual(stat(url.path, &st), 0); XCTAssertEqual(st.st_mode & 0o777, 0o600)
    }
    func testGoalIsReDerivedFromTheTranscriptAndAnOldFileWithGoalStillLoads() throws {
        let dir = url.deletingLastPathComponent(), t = dir.appendingPathComponent("t.jsonl")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"type":"user","message":{"content":"Fix the login bug"}}"#.write(to: t, atomically: true, encoding: .utf8)
        var s = full(); s.transcriptPath = t.path; s.title = nil
        try SnapshotIO.save([s], to: url)
        XCTAssertEqual(SnapshotIO.load(from: url).first?.goal, "Fix the login bug")
        // A file written by an older build carries "goal": it is ignored, the transcript wins.
        let old = #"{"version":1,"sessions":[{"id":"o","project":"p","cwd":"/p","goal":"STALE-PROMPT","transcriptPath":"\#(t.path)","startedAt":"2027-01-15T08:00:00Z","lastEventAt":"2027-01-15T08:00:00Z"}]}"#
        try old.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SnapshotIO.load(from: url).map(\.goal), ["Fix the login bug"])
    }
    func testMissingOrCorruptFileLoadsEmpty() throws {
        XCTAssertEqual(SnapshotIO.load(from: url), [])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(SnapshotIO.load(from: url), [])
    }
}
