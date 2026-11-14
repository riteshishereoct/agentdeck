import XCTest
@testable import AgentDeckCore

final class IngestTests: XCTestCase {
    private let meta = HookMeta(pid: 4242, host: "com.todesktop.230313mzl4w4u92", entrypoint: "claude-vscode")
    private func decode(_ json: String) -> HookInput { try! HookInput.decode(Data(json.utf8)) }

    func testPreToolUseBashEvent() {
        let e = Ingest.event(.preToolUse, Fixture.hookInput("PreToolUse-Bash"), meta: meta, now: Make.t0)
        XCTAssertEqual(e.kind, .hook(.preToolUse)); XCTAssertEqual(e.sessionId, "s-1111")
        XCTAssertEqual(e.tool, "Bash"); XCTAssertEqual(e.toolUseId, "toolu_01"); XCTAssertEqual(e.inputPreview, "Run tests")   // G-NOW: the agent's own description
        XCTAssertEqual(e.pid, 4242); XCTAssertEqual(e.host, "com.todesktop.230313mzl4w4u92"); XCTAssertEqual(e.entrypoint, "claude-vscode")
        XCTAssertEqual(e.cwd, "/Users/me/proj"); XCTAssertEqual(e.transcriptPath, "/tmp/adk-fixture/s-1111.jsonl")
        XCTAssertEqual(e.permissionMode, "default"); XCTAssertEqual(e.ts, Make.t0); XCTAssertNil(e.text)
    }
    func testTextAndAgentFieldsPerHook() {
        XCTAssertEqual(Ingest.event(.userPromptSubmit, Fixture.hookInput("UserPromptSubmit"), meta: meta, now: Make.t0).text, "Fix the S3 pool leak\nthen run the tests")
        XCTAssertEqual(Ingest.event(.stop, Fixture.hookInput("Stop"), meta: meta, now: Make.t0).text?.hasPrefix("Added compound index."), true)
        let n = Ingest.event(.notification, Fixture.hookInput("Notification-idle_prompt"), meta: meta, now: Make.t0)
        XCTAssertEqual(n.text, "Claude is waiting for your input"); XCTAssertEqual(n.notificationType, "idle_prompt")
        let s = Ingest.event(.subagentStart, Fixture.hookInput("SubagentStart"), meta: meta, now: Make.t0)
        XCTAssertEqual(s.agentId, "a-1"); XCTAssertEqual(s.agentType, "code-reviewer")
        XCTAssertEqual(Ingest.event(.subagentStop, Fixture.hookInput("SubagentStop-internal"), meta: meta, now: Make.t0).agentType, "")
        let ss = Ingest.event(.sessionStart, Fixture.hookInput("SessionStart"), meta: HookMeta(), now: Make.t0)
        XCTAssertNil(ss.inputPreview); XCTAssertNil(ss.tool); XCTAssertNil(ss.pid)
    }
    func testPermissionRequestHasNoToolUseIdButHasPreview() {
        let e = Ingest.event(.permissionRequest, Fixture.hookInput("PermissionRequest-Bash"), meta: meta, now: Make.t0)
        XCTAssertNil(e.toolUseId); XCTAssertEqual(e.inputPreview, "Bash: npm test")
    }
    func testPreviewCutsOnCharacterBoundaryAtLimit() {
        XCTAssertEqual(Ingest.previewLimit, 2048)
        XCTAssertEqual(Ingest.preview(String(repeating: "a", count: 3000)).utf8.count, 2048)
        let euro = Ingest.preview(String(repeating: "€", count: 1000))   // 3 bytes each: 682 fit (2046 bytes), never a split scalar
        XCTAssertEqual(euro.utf8.count, 2046); XCTAssertEqual(euro.count, 682)
        let e = Ingest.event(.preToolUse, decode(#"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"\#(String(repeating: "€", count: 1000))"}}"#), meta: meta, now: Make.t0)
        XCTAssertEqual(e.inputPreview?.utf8.count, 2046)   // "Bash: " is 6 bytes, then 680 euros
        XCTAssertEqual(e.inputPreview?.hasPrefix("Bash: €"), true)
    }
    func testPreviewMasksTokensEvenAcrossTheCutLine() {
        let e = Ingest.event(.preToolUse, decode(#"{"session_id":"s","tool_name":"Bash","tool_input":{"command":"curl -H 'Authorization: Bearer abcdefghijklmnop1234' x"}}"#), meta: meta, now: Make.t0)
        XCTAssertEqual(e.inputPreview, "Bash: curl -H 'Authorization: Bearer abcd••••' x")
        let padded = String(repeating: "a", count: 2030) + " sk-abcdefghijklmnopqrstuvwx"
        XCTAssertFalse(Ingest.preview(padded).contains("sk-abcdefghi"))   // masked before cutting, no partial secret leaks
    }
}
