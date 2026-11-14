import XCTest
@testable import AgentDeckCore

final class TranscriptParserTests: XCTestCase {
    private let now = Make.t0
    private func lines(_ name: String) -> [Data] { Fixture.data("transcripts/\(name).jsonl").split(separator: 10, omittingEmptySubsequences: false).map { Data($0) } }
    private func parse(_ name: String, _ i: Int = 0) -> [AgentEvent] { TranscriptParser.events(fromLine: lines(name)[i], sessionId: "s1", now: now) }

    func testAssistantLineYieldsModelAndJoinedText() {
        let e = parse("assistant-text"); XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].kind, .transcriptAssistant); XCTAssertEqual(e[0].model, "claude-opus-5-5")
        XCTAssertEqual(e[0].text, "Added the index.\nQuery is faster."); XCTAssertEqual(e[0].sessionId, "s1")
        XCTAssertEqual(e[0].ts, Date(timeIntervalSince1970: 1_794_564_900))   // the line's own timestamp
    }
    func testToolUseYieldsAssistantThenToolUse() {
        let e = parse("assistant-tool-use"); XCTAssertEqual(e.map(\.kind), [.transcriptAssistant, .transcriptToolUse])
        XCTAssertEqual(e[1].tool, "Bash"); XCTAssertEqual(e[1].toolUseId, "toolu_01"); XCTAssertNil(e[0].text)
    }
    func testToolResultYieldsIsErrorFlag() {
        XCTAssertEqual(parse("user-tool-result", 0).map(\.kind), [.transcriptToolResult(isError: false)])
        let bad = parse("user-tool-result", 1); XCTAssertEqual(bad.map(\.kind), [.transcriptToolResult(isError: true)]); XCTAssertEqual(bad[0].toolUseId, "toolu_02")
    }
    func testSummaryLineYieldsTitleAndFallsBackToNowWhenUntimestamped() {
        let e = parse("summary"); XCTAssertEqual(e.map(\.kind), [.transcriptTitle]); XCTAssertEqual(e[0].text, "Fix S3 pool leak"); XCTAssertEqual(e[0].ts, now)
    }
    func testAiTitleLineYieldsTitleAndLatestWinsInTheReducer() throws {
        func ev(_ json: String) -> [AgentEvent] { TranscriptParser.events(fromLine: Data(json.utf8), sessionId: "s1", now: now) }
        let a = ev(#"{"type":"ai-title","aiTitle":"Fix login redirect","sessionId":"s1"}"#)
        XCTAssertEqual(a.map(\.kind), [.transcriptTitle]); XCTAssertEqual(a[0].text, "Fix login redirect"); XCTAssertEqual(a[0].ts, now)
        XCTAssertEqual(ev(#"{"type":"ai-title","aiTitle":"   ","sessionId":"s1"}"#), [])
        XCTAssertEqual(ev(#"{"type":"ai-title","sessionId":"s1"}"#), [])
        XCTAssertEqual(ev(#"{"type":"last-prompt","lastPrompt":"hello","sessionId":"s1"}"#), [])
        let secret = "AKIA" + "ABCDEFGHIJKLMNOP"
        XCTAssertEqual(ev(#"{"type":"ai-title","aiTitle":"Use \#(secret)"}"#)[0].text, "Use AKIA••••")
    }
    func testTodoWriteYieldsAbsoluteProgress() {
        XCTAssertEqual(parse("todowrite").map(\.kind), [.transcriptToolUse, .transcriptTasks(TaskProgress(done: 1, total: 3))])
    }
    func testTaskCreateAndUpdateAccumulateThroughATally() {
        var tally = TaskTally(); var last: [EventKind] = []
        for (i, want) in [(0, TaskProgress(done: 0, total: 1)), (1, TaskProgress(done: 0, total: 2)), (2, TaskProgress(done: 1, total: 2))] {
            last = TranscriptParser.events(fromLine: lines("tasks")[i], sessionId: "s1", now: now, tally: &tally).map(\.kind)
            XCTAssertEqual(last.last, .transcriptTasks(want))
        }
        let again = TranscriptParser.events(fromLine: lines("tasks")[2], sessionId: "s1", now: now, tally: &tally).map(\.kind)   // same update twice: no double count
        XCTAssertEqual(again.last, .transcriptTasks(TaskProgress(done: 1, total: 2)))
    }
    func testUnknownAndMalformedLinesYieldNothingAndNeverThrow() {
        for i in 0..<lines("unknown-and-malformed").count { XCTAssertEqual(parse("unknown-and-malformed", i), [], "line \(i)") }
        XCTAssertEqual(TranscriptParser.events(fromLine: Data(), sessionId: "s", now: now), [])
    }
    func testLongAssistantTextIsCappedAndMasked() {
        let j = #"{"type":"assistant","message":{"content":[{"type":"text","text":"sk-abcdefghijklmnopqrstuvwx \#(String(repeating: "a", count: 5000))"}]}}"#
        let e = TranscriptParser.events(fromLine: Data(j.utf8), sessionId: "s", now: now)
        XCTAssertLessThanOrEqual(e[0].text?.utf8.count ?? 0, Ingest.previewLimit); XCTAssertTrue(e[0].text?.hasPrefix("sk-a••••") ?? false)
    }
}
