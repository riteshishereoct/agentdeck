import XCTest
@testable import AgentDeckCore

final class SessionLabelsTests: XCTestCase {
    func testSnapshotRecoversOriginalWorkspaceAndGoalWithoutReplayingActivity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("session.jsonl")
        let line = #"{"type":"user","cwd":"/Users/me/my-project","message":{"content":"<pasted_content id=\"x\">\nBuild the hover overlay\n</pasted_content>"}}"#
        try Data((line + "\n").utf8).write(to: transcript)
        let session = Session(id: "s", project: "mtest", cwd: "/private/tmp/mtest", transcriptPath: transcript.path,
                              goal: "<pasted_content id=\"x\">", startedAt: Make.t0, lastEventAt: Make.t(3))
        let snapshot = dir.appendingPathComponent("sessions.json")
        try SnapshotIO.save([session], to: snapshot)
        let restored = try XCTUnwrap(SnapshotIO.load(from: snapshot).first)
        XCTAssertEqual(restored.project, "my-project")
        XCTAssertEqual(restored.goal, "Build the hover overlay")
        XCTAssertEqual(restored.cwd, "/private/tmp/mtest")
        XCTAssertEqual(restored.state, .idle)
        XCTAssertEqual(restored.lastEventAt, Make.t(3))
        XCTAssertEqual(restored.stepCount, 0)
        XCTAssertNil(restored.currentStep)
    }

    func testRestoringContextTakesLatestAiTitleWithinFirstMegabyteAndOnlyTheTitle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pad = String(repeating: "x", count: 1_100_000)
        let lines = [
            #"{"type":"user","cwd":"/Users/me/my-project","timestamp":"2026-11-14T10:00:00.000Z","message":{"content":"<ide_opened_file>/a.ts</ide_opened_file>Fix login"}}"#,
            #"{"type":"ai-title","aiTitle":"First title","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash"}]}}"#,
            #"{"type":"ai-title","aiTitle":"Latest title","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"nope"}"#,
            #"{"type":"summary","summary":"x","pad":""# + pad + #""}"#,
            #"{"type":"ai-title","aiTitle":"Beyond the bound","sessionId":"s"}"#,
        ]
        let transcript = dir.appendingPathComponent("s.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
        let pending = Make.request("r1")
        let session = Session(id: "s", project: "p", cwd: "/tmp/p", transcriptPath: transcript.path, pending: [pending],
                              startedAt: Make.t0, lastEventAt: Make.t(3))
        let r = SessionLabels.restoringContext(session)
        XCTAssertEqual(r.title, "Latest title"); XCTAssertEqual(r.goal, "Fix login")
        XCTAssertEqual(r.lastEventAt, Make.t(3)); XCTAssertEqual(r.startedAt, Make.t0)
        XCTAssertEqual(r.stepCount, 0); XCTAssertNil(r.currentStep); XCTAssertEqual(r.pending.map(\.id), ["r1"]); XCTAssertEqual(r.state, session.state)
        var kept = session; kept.title = "Live title"   // a title already learned from the live stream is not overwritten
        XCTAssertEqual(SessionLabels.restoringContext(kept).title, "Live title")
    }
}
