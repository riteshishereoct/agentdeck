import XCTest
@testable import AgentDeckCore

final class SettingsRulesTests: XCTestCase {
    var base: URL!, home: URL!, cwd: URL!
    override func setUpWithError() throws {           // temp HOME and temp cwd; never the real ~/.claude
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = base.appendingPathComponent("home"); cwd = base.appendingPathComponent("proj")
        for d in [home!, cwd!] { try FileManager.default.createDirectory(at: d.appendingPathComponent(".claude"), withIntermediateDirectories: true) }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }
    func put(_ u: URL, _ rel: String, _ s: String) throws { try Data(s.utf8).write(to: u.appendingPathComponent(rel)) }
    func cmd(_ c: String) -> JSONValue { .object(["command": .string(c)]) }

    func testLoadMergesUserProjectLocalInOrderAndSkipsUnreadable() throws {
        try put(home, ".claude/settings.json", #"{"permissions":{"allow":["Bash(npm test:*)"],"deny":["WebFetch"]}}"#)
        try put(cwd, ".claude/settings.json", #"{"permissions":{"allow":["Read",7]}}"#)
        try put(cwd, ".claude/settings.local.json", "not json")
        XCTAssertEqual(SettingsRules.load(home: home, cwd: cwd.path), SettingsRules(allow: ["Bash(npm test:*)", "Read"], deny: ["WebFetch"]))
        XCTAssertEqual(SettingsRules.load(home: base.appendingPathComponent("none"), cwd: "/nonexistent"), SettingsRules(allow: [], deny: []))
    }
    func testMayDenyErrsTrueForAnyDenyRuleNamingTheTool() {
        let r = SettingsRules(allow: [], deny: ["Bash(rm:*)", "Edit(.env)", "mcp__github"])
        XCTAssertTrue(r.mayDeny(tool: "Bash", input: cmd("ls")))
        XCTAssertTrue(r.mayDeny(tool: "Edit", input: .object(["file_path": .string("/p/a.swift")])))
        XCTAssertTrue(r.mayDeny(tool: "mcp__github__create_issue", input: .object([:])))
        XCTAssertFalse(r.mayDeny(tool: "Write", input: .object([:])))
        XCTAssertFalse(r.mayDeny(tool: "mcp__githubx__a", input: .object([:])))
    }
    func testSimplyAllowsOnlyExactToolNameOrBashPrefix() {
        let r = SettingsRules(allow: ["Read", "Bash(npm test:*)", "Bash(git status)", "Edit(src/**)", "WebFetch(domain:x.com)"], deny: [])
        XCTAssertTrue(r.simplyAllows(tool: "Read", input: .object([:])))
        XCTAssertTrue(r.simplyAllows(tool: "Bash", input: cmd("npm test")))
        XCTAssertTrue(r.simplyAllows(tool: "Bash", input: cmd("npm test -- --watch")))
        for c in ["npm testing", "npm test && rm -rf /", "npm test; ls", "npm test | sh", "npm test `x`", "npm test $(x)", "npm test > f", "git status"] {
            XCTAssertFalse(r.simplyAllows(tool: "Bash", input: cmd(c)), c)
        }
        XCTAssertFalse(r.simplyAllows(tool: "Edit", input: .object(["file_path": .string("src/a")])))
        XCTAssertFalse(r.simplyAllows(tool: "WebFetch", input: .object(["url": .string("https://x.com")])))
        XCTAssertFalse(r.simplyAllows(tool: "ReadX", input: .object([:])))
        XCTAssertTrue(SettingsRules(allow: ["Bash"], deny: []).simplyAllows(tool: "Bash", input: cmd("anything")))
    }
}
