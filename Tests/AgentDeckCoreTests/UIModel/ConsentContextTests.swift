import XCTest
@testable import AgentDeckCore

final class ConsentContextTests: XCTestCase {
    private func req(_ tool: String, _ input: [String: JSONValue], risk: Risk = Risk(level: .low, reason: "Routine action")) -> Request {
        Request(id: "r", sessionId: "s", kind: .permission, hook: .permissionRequest, tool: tool, preview: "p", fullInput: .object(input),
                risk: risk, channel: .race, createdAt: Make.t0)
    }
    private let session = Session(id: "s", project: "probe", cwd: "/w/probe", goal: "Build the thing", latestAsk: "Run the tests please",
                                  startedAt: Make.t0, lastEventAt: Make.t0)

    func testBashShowsRealCommandSeparateFromAgentReasonAndScope() {
        let c = ConsentContext.make(req("Bash", ["command": .string("rm -rf build && swift test"), "description": .string("Clean and test")]), session: session)
        XCTAssertEqual(c.what, "Run a shell command")
        XCTAssertEqual(c.detailLabel, "Command")
        XCTAssertEqual(c.detail, "rm -rf build && swift test")            // never replaced by the description
        XCTAssertEqual(c.reason, "Agent's reason: Clean and test")
        XCTAssertEqual(c.scope, "Runs in /w/probe with your user permissions")
        XCTAssertEqual(c.task, "Run the tests please")
        XCTAssertEqual(c.risk, "LOW · Routine action")
    }
    func testMissingReasonIsSaidNotInvented() {
        XCTAssertEqual(ConsentContext.make(req("Edit", ["file_path": .string("/w/a.swift"), "old_string": .string("a"), "new_string": .string("b")]), session: nil).reason,
                       "Reason not provided")
    }
    func testEditShowsFileFullDiffAndExactScope() {
        let new = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let c = ConsentContext.make(req("Edit", ["file_path": .string("/w/a.swift"), "old_string": .string("x"), "new_string": .string(new)]), session: session)
        XCTAssertEqual(c.what, "Edit a file"); XCTAssertEqual(c.scope, "Changes only /w/a.swift")
        XCTAssertTrue(c.detail.hasPrefix("/w/a.swift\n− x\n+ line 1")); XCTAssertTrue(c.detail.contains("+ line 30"))   // not cut at 6 lines
    }
    func testSecretsAreMaskedInCommandAndReason() {
        let c = ConsentContext.make(req("Bash", ["command": .string("curl -H 'Authorization: Bearer abcd1234efgh5678' x"),
                                                 "description": .string("use token sk-abcdefghijklmnop1234")]), session: session)
        XCTAssertFalse(c.detail.contains("abcd1234efgh5678")); XCTAssertFalse(c.reason.contains("abcdefghijklmnop1234"))
    }
    func testVeryLongDetailIsCappedWithAVisibleNotice() {
        let c = ConsentContext.make(req("Bash", ["command": .string(String(repeating: "a", count: 9000))]), session: nil)
        XCTAssertTrue(c.detail.contains("\n… 1500 characters not shown (open in Cursor to see all) …\n"))
        XCTAssertTrue(c.incomplete); XCTAssertTrue(c.requiresHold)
        XCTAssertEqual(c.scope, "Runs with your user permissions (folder unknown)")
    }
    func testWebFetchAndMcpScopes() {
        XCTAssertEqual(ConsentContext.make(req("WebFetch", ["url": .string("https://api.example.com/x")]), session: nil).scope, "Sends a request to api.example.com")
        let m = ConsentContext.make(req("mcp__github__create_issue", ["title": .string("t")]), session: nil)
        XCTAssertEqual(m.what, "Use the github tool create_issue"); XCTAssertEqual(m.scope, "Acts through the github MCP server")
        XCTAssertTrue(m.detail.contains("\"title\" : \"t\""))
    }
    func testBashWithoutCommandStillShowsTheRealInput() {
        let c = ConsentContext.make(req("Bash", ["timeout": .number(5)]), session: nil)
        XCTAssertTrue(c.detail.contains("\"timeout\""))
    }
    func testMultiEditShowsEveryEditAndWriteShowsContent() {
        let m = ConsentContext.make(req("MultiEdit", ["file_path": .string("/w/a.swift"), "edits": .array([
            .object(["old_string": .string("a"), "new_string": .string("b")]), .object(["old_string": .string("c"), "new_string": .string("d")])])]), session: nil)
        XCTAssertEqual(m.detail, "/w/a.swift\n− a\n+ b\n− c\n+ d")
        let w = ConsentContext.make(req("Write", ["file_path": .string("/w/n.txt"), "content": .string("hi")]), session: nil)
        XCTAssertEqual(w.what, "Create or overwrite a file"); XCTAssertEqual(w.detail, "/w/n.txt\n+ hi")
        XCTAssertEqual(w.scope, "Writes /w/n.txt (replaces its whole contents)")
    }
    func testNotebookEditShowsTheNewSource() {
        let c = ConsentContext.make(req("NotebookEdit", ["notebook_path": .string("/w/n.ipynb"), "new_source": .string("print(1)")]), session: nil)
        XCTAssertEqual(c.detail, "/w/n.ipynb\nprint(1)")
    }
    func testPlanReviewShowsThePlan() {
        let c = ConsentContext.make(req("ExitPlanMode", ["plan": .string("1. do x\n2. do y")]), session: nil)
        XCTAssertEqual(c.what, "Review the agent's plan"); XCTAssertEqual(c.detailLabel, "Plan"); XCTAssertEqual(c.detail, "1. do x\n2. do y")
    }
    func testUnknownToolShowsItsInputAndNoInventedReason() {
        let c = ConsentContext.make(req("Frobnicate", ["x": .string("y")]), session: nil)
        XCTAssertEqual(c.what, "Use Frobnicate"); XCTAssertEqual(c.detailLabel, "Input"); XCTAssertTrue(c.detail.contains("\"x\" : \"y\""))
        XCTAssertEqual(c.reason, ConsentContext.reasonMissing)
    }
    func testIdentityKeepsShortIdAndProjectSeparateFromTheWrappableTitle() {
        let long = Session(id: "405d83ffee", project: "agentdeck-probe", cwd: "/w", title: "Agentdeck-d5a.txt file creation " + String(repeating: "x", count: 80),
                           startedAt: Make.t0, lastEventAt: Make.t0)
        let c = ConsentContext.make(req("Bash", ["command": .string("ls")]), session: long)
        XCTAssertEqual(c.identity, "#405d83 · agentdeck-probe")
        XCTAssertTrue(c.sessionTitle?.hasPrefix("Agentdeck-d5a.txt file creation") ?? false)
        XCTAssertEqual(ConsentContext.make(req("Bash", ["command": .string("ls")]), session: nil).identity, "#s")
    }
    func testHeadlineDoesNotRepeatTheTool() {
        XCTAssertEqual(CardFormat.headline(UI.request("a", preview: "Bash: touch x")), "Bash: touch x")
        XCTAssertEqual(CardFormat.headline(UI.request("a", tool: "mcp__github__create_issue", preview: "github.create_issue")), "github.create_issue")
    }
    // C1: notification-only cards have no tool input object; building their context must never crash.
    func testNonObjectInputShowsTheNoticeAndNeverCrashes() {
        for input: JSONValue in [.null, .string("raw"), .number(3), .array([.number(1)])] {
            let r = Request(id: "r", sessionId: "s", kind: .permission, hook: .notification, tool: "", preview: "Claude needs your permission to use Bash",
                            fullInput: input, risk: Risk(level: .low, reason: "r"), channel: .notify, createdAt: Make.t0)
            let c = ConsentContext.make(r, session: session)
            XCTAssertEqual(c.what, "Approve or deny in Cursor"); XCTAssertEqual(c.detailLabel, "Notice")
            XCTAssertEqual(c.detail, "Claude needs your permission to use Bash"); XCTAssertEqual(c.reason, ConsentContext.reasonMissing)
        }
    }
    // H1/H2: anything cut or too long to see at once forces a hold, and the real end of the command is always on the card.
    func testTruncatedDiffIsIncompleteAndTailShowsTheEnd() {
        let huge = (1...450).map { "l\($0)" }.joined(separator: "\n")
        let e = ConsentContext.make(req("Write", ["file_path": .string("/w/a"), "content": .string(huge)]), session: nil)
        XCTAssertTrue(e.incomplete); XCTAssertTrue(e.detail.hasSuffix("+ … 50 more lines not shown"))
        let short = ConsentContext.make(req("Bash", ["command": .string("ls")]), session: nil)
        XCTAssertFalse(short.incomplete); XCTAssertFalse(short.overflows); XCTAssertFalse(short.requiresHold)
        let long = ConsentContext.make(req("Bash", ["command": .string((1...12).map { "echo \($0)" }.joined(separator: "\n") + " && rm -rf ~")]), session: nil)
        XCTAssertFalse(long.incomplete); XCTAssertTrue(long.overflows); XCTAssertTrue(long.requiresHold)
        XCTAssertEqual(long.tail, "echo 10\necho 11\necho 12 && rm -rf ~")
        let oneLine = ConsentContext.make(req("Bash", ["command": .string(String(repeating: "a", count: 9000) + " && rm -rf ~")]), session: nil)
        XCTAssertTrue(oneLine.tail.hasPrefix("…")); XCTAssertTrue(oneLine.tail.hasSuffix("&& rm -rf ~")); XCTAssertEqual(oneLine.tail.count, 301)
    }
}
