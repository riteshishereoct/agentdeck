import XCTest
@testable import AgentDeckCore

final class StepLabelTests: XCTestCase {
    private func lines(_ n: Int) -> JSONValue { .string(Array(repeating: "x", count: n).joined(separator: "\n")) }
    func testActivityUsesAgentDescriptionButConsentLabelKeepsCommand() {   // G-NOW; cards must show the real command
        let bash: JSONValue = .object(["command": .string("swift test 2>&1 | tail"), "description": .string("Run regression tests\nmore")])
        XCTAssertEqual(StepLabel.activity(tool: "Bash", input: bash), "Run regression tests")
        XCTAssertEqual(StepLabel.label(tool: "Bash", input: bash), "Bash: swift test 2>&1 | tail")
        XCTAssertEqual(StepLabel.activity(tool: "Agent", input: .object(["description": .string("Review consent paths")])), "Agent: Review consent paths")
        XCTAssertEqual(StepLabel.activity(tool: "Bash", input: .object(["command": .string("ls"), "description": .string("  ")])), "Bash: ls")
        XCTAssertEqual(StepLabel.activity(tool: "Read", input: .object(["file_path": .string("/a/b.swift"), "description": .string("x")])), "Read b.swift")
    }
    func testLabels() {
        let cases: [(String, JSONValue, String)] = [
            ("Bash", .object(["command": .string("npm test\nsecond line")]), "Bash: npm test"),
            ("Bash", .object(["command": .string("   ")]), "Bash"),
            ("Edit", .object(["file_path": .string("/a/b/routes.js"), "old_string": lines(3), "new_string": lines(12)]), "Edit routes.js +12 −3"),
            ("Edit", .object(["file_path": .string("/a/b/routes.js")]), "Edit routes.js"),
            ("Write", .object(["file_path": .string("/a/notes.md"), "content": .string("a\nb\nc\nd\ne\n")]), "Write notes.md +5"),
            ("MultiEdit", .object(["file_path": .string("/a/app.ts"), "edits": .array([
                .object(["old_string": lines(2), "new_string": lines(3)]), .object(["old_string": lines(1), "new_string": lines(1)])])]), "MultiEdit app.ts +4 −3"),
            ("NotebookEdit", .object(["notebook_path": .string("/a/nb.ipynb")]), "NotebookEdit nb.ipynb"),
            ("Read", .object(["file_path": .string("/a/x.swift")]), "Read x.swift"),
            ("Grep", .object(["pattern": .string("foo")]), "Grep foo"),
            ("Glob", .object(["pattern": .string("**/*.js")]), "Glob **/*.js"),
            ("WebFetch", .object(["url": .string("https://example.com/x")]), "WebFetch https://example.com/x"),
            ("WebSearch", .object(["query": .string("swift actors")]), "WebSearch swift actors"),
            ("Task", .object(["subagent_type": .string("code-reviewer")]), "Agent: code-reviewer"),
            ("Agent", .object(["subagent_type": .string("tests")]), "Agent: tests"),
            ("Task", .object([:]), "Agent"),
            ("mcp__github__create_issue", .object([:]), "github.create_issue"),
            ("mcp__x__a__b", .object([:]), "x.a__b"),
            ("AskUserQuestion", .object(["questions": .array([.object(["question": .string("Which DB?")])])]), "Question: Which DB?"),
            ("ExitPlanMode", .object([:]), "Plan review"),
            ("Foo", .null, "Foo"),
        ]
        for (tool, input, want) in cases { XCTAssertEqual(StepLabel.label(tool: tool, input: input), want, tool) }
    }
}
