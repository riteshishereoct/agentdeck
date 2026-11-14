import XCTest
@testable import AgentDeckCore

final class TranscriptTailerTests: XCTestCase {
    private var dir: URL!
    private var events: [AgentEvent] = []
    private var tailer: TranscriptTailer!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-tail-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        events = []; tailer = TranscriptTailer(emit: { [unowned self] in self.events.append($0) })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private var file: URL { dir.appendingPathComponent("s1.jsonl") }
    private func use(_ id: String) -> String { #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{}}]}}"# }
    private func append(_ s: String) {
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close() } else { try? s.write(to: file, atomically: true, encoding: .utf8) }
    }
    private var ids: [String] { events.compactMap(\.toolUseId) }

    func testInactiveSessionPollsAtMostOncePerSecondWhileActiveSessionKeepsUp() {
        let t = Date(timeIntervalSince1970: 100)
        append(use("a") + "\n"); tailer.track(sessionId: "s1", path: file.path)
        let activeFile = dir.appendingPathComponent("active.jsonl")
        try! (use("active-a") + "\n").write(to: activeFile, atomically: true, encoding: .utf8)
        tailer.track(sessionId: "s2", path: activeFile.path)
        tailer.poll(now: t, activeSessionIds: ["s2"])
        append(use("b") + "\n")
        let handle = try! FileHandle(forWritingTo: activeFile); handle.seekToEndOfFile()
        handle.write(Data((use("active-b") + "\n").utf8)); try! handle.close()
        tailer.poll(now: t.addingTimeInterval(0.1), activeSessionIds: ["s2"])
        XCTAssertEqual(events.filter { $0.sessionId == "s1" }.compactMap(\.toolUseId), ["a"])
        XCTAssertEqual(events.filter { $0.sessionId == "s2" }.compactMap(\.toolUseId), ["active-a", "active-b"])
        tailer.poll(now: t.addingTimeInterval(1), activeSessionIds: ["s2"])
        XCTAssertEqual(events.filter { $0.sessionId == "s1" }.compactMap(\.toolUseId), ["a", "b"])
    }
    func testReadsAppendedBytesOnly() {
        append(use("a") + "\n" + use("b") + "\n"); tailer.track(sessionId: "s1", path: file.path); tailer.poll()
        XCTAssertEqual(ids, ["a", "b"])
        append(use("c") + "\n"); tailer.poll(); XCTAssertEqual(ids, ["a", "b", "c"])   // only the new line
        tailer.poll(); XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(events.allSatisfy { $0.sessionId == "s1" })
    }
    func testTrackIsIdempotentAndUntrackStops() {
        append(use("a") + "\n"); tailer.track(sessionId: "s1", path: file.path); tailer.poll()
        tailer.track(sessionId: "s1", path: file.path); tailer.poll(); XCTAssertEqual(ids, ["a"])
        tailer.untrack(sessionId: "s1"); append(use("b") + "\n"); tailer.poll(); XCTAssertEqual(ids, ["a"])
    }
    func testPartialLastLineIsBufferedUntilItsNewline() {
        let line = use("a"); tailer.track(sessionId: "s1", path: file.path)
        append(String(line.prefix(30))); tailer.poll(); XCTAssertTrue(events.isEmpty)
        append(String(line.dropFirst(30)) + "\n"); tailer.poll(); XCTAssertEqual(ids, ["a"])
    }
    func testLinesOverMaxLineAreSkippedAndExactlyMaxLineIsKept() {
        let base = #"{"type":"assistant","message":{"content":[{"type":"text","text":""}]}}"#
        let exact = #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(String(repeating: "x", count: TranscriptTailer.maxLine - base.utf8.count))"}]}}"#
        XCTAssertEqual(exact.utf8.count, TranscriptTailer.maxLine)
        let over = exact.replacingOccurrences(of: "\"}]}}", with: "x\"}]}}")
        append(over + "\n" + exact + "\n" + use("after") + "\n"); tailer.track(sessionId: "s1", path: file.path); tailer.poll()
        XCTAssertEqual(events.filter { $0.kind == .transcriptAssistant }.count, 1)   // `exact` is kept, `over` is skipped (`after` has no text or model)
        XCTAssertEqual(ids, ["after"])
    }
    func testOversizeLineWithoutNewlineIsDroppedAcrossPolls() {
        tailer.track(sessionId: "s1", path: file.path)
        append(String(repeating: "y", count: 300_000)); tailer.poll(); XCTAssertTrue(events.isEmpty)
        append("tail\n" + use("ok") + "\n"); tailer.poll(); XCTAssertEqual(ids, ["ok"])
    }
    func testTruncationResetsToTheStart() {
        append(use("a") + "\n" + use("b") + "\n"); tailer.track(sessionId: "s1", path: file.path); tailer.poll()
        try? (use("z") + "\n").write(to: file, atomically: false, encoding: .utf8)   // rewritten shorter
        tailer.poll(); XCTAssertEqual(ids, ["a", "b", "z"])
    }
    func testMissingFileIsToleratedUntilItAppears() {
        tailer.track(sessionId: "s1", path: file.path); tailer.poll(); XCTAssertTrue(events.isEmpty)
        append(use("a") + "\n"); tailer.poll(); XCTAssertEqual(ids, ["a"])
    }
    func testTaskTallyIsKeptPerSessionAcrossPolls() {
        let create = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"TaskCreate","input":{"subject":"x"}}]}}"#
        tailer.track(sessionId: "s1", path: file.path); append(create + "\n"); tailer.poll(); append(create + "\n"); tailer.poll()
        XCTAssertEqual(events.last?.kind, .transcriptTasks(TaskProgress(done: 0, total: 2)))
    }
    func testBigFileIsDrainedInBoundedChunks() {
        let line = use("n") + String(repeating: " ", count: 500) + "\n"
        append(String(repeating: line, count: 3000)); tailer.track(sessionId: "s1", path: file.path)
        tailer.poll(); XCTAssertGreaterThan(events.count, 0); XCTAssertLessThan(events.count, 3000)   // one poll reads at most 1 MiB
        for _ in 0..<10 { tailer.poll() }
        XCTAssertEqual(ids.count, 3000)
    }
}
