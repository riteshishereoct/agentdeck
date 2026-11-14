import XCTest
@testable import AgentDeckCore

final class HookInputTests: XCTestCase {
    func testEveryHookKindFixtureDecodes() {
        for kind in HookKind.allCases {
            let i = Fixture.hookInput(kind.rawValue)
            XCTAssertEqual(i.hookEventName, kind.rawValue)
            XCTAssertEqual(i.sessionId, "s-1111"); XCTAssertEqual(i.cwd, "/Users/me/proj")
            XCTAssertEqual(i.transcriptPath, "/tmp/adk-fixture/s-1111.jsonl"); XCTAssertEqual(i.permissionMode, "default")
        }
    }
    func testBashToolFields() {
        let i = Fixture.hookInput("PreToolUse-Bash")
        XCTAssertEqual(i.toolName, "Bash"); XCTAssertEqual(i.toolUseId, "toolu_01")
        XCTAssertEqual(i.toolInput?["command"]?.stringValue, "npm test")
        XCTAssertTrue(i.permissionSuggestions.isEmpty); XCTAssertFalse(i.personOnly)
    }
    func testPermissionRequestHasSuggestionsAndNoToolUseId() {
        let i = Fixture.hookInput("PermissionRequest-Bash")
        XCTAssertNil(i.toolUseId); XCTAssertEqual(i.permissionSuggestions.count, 1)
        XCTAssertEqual(i.permissionSuggestions[0]["type"]?.stringValue, "addRules")
    }
    func testNotificationAndSubagentFields() {
        XCTAssertEqual(Fixture.hookInput("Notification-idle_prompt").notificationType, "idle_prompt")
        XCTAssertEqual(Fixture.hookInput("Notification-permission_prompt").message, "Claude needs your permission to use Bash")
        XCTAssertEqual(Fixture.hookInput("SubagentStart").agentId, "a-1")
        XCTAssertEqual(Fixture.hookInput("SubagentStop-internal").agentType, "")   // "" is kept, not nil
        XCTAssertEqual(Fixture.hookInput("Stop").lastAssistantMessage?.hasPrefix("Added compound index."), true)
        XCTAssertEqual(Fixture.hookInput("UserPromptSubmit").prompt?.hasPrefix("Fix the S3"), true)
    }
    func testDefaultsWhenOnlySessionIdPresent() throws {
        let i = try HookInput.decode(Data(#"{"session_id":"x"}"#.utf8))
        XCTAssertEqual(i.sessionId, "x"); XCTAssertEqual(i.permissionSuggestions, [])
        XCTAssertNil(i.toolName); XCTAssertNil(i.cwd); XCTAssertFalse(i.personOnly)
    }
    func testDecodeErrors() {
        XCTAssertThrowsError(try HookInput.decode(Data(#"{"cwd":"/"}"#.utf8))) { XCTAssertEqual($0 as? HookInputError, .missingSessionId) }
        XCTAssertThrowsError(try HookInput.decode(Data(#"{"session_id":5}"#.utf8))) { XCTAssertEqual($0 as? HookInputError, .missingSessionId) }
        XCTAssertThrowsError(try HookInput.decode(Data("[1]".utf8))) { XCTAssertEqual($0 as? HookInputError, .notAnObject) }
        XCTAssertThrowsError(try HookInput.decode(Data("nope".utf8)))
    }
    func testPersonOnlyOnlyForBooleanTrueAndUnknownKeysKept() throws {
        XCTAssertTrue(try HookInput.decode(Data(#"{"session_id":"x","person_only":true}"#.utf8)).personOnly)
        XCTAssertFalse(try HookInput.decode(Data(#"{"session_id":"x","person_only":"true"}"#.utf8)).personOnly)
        XCTAssertEqual(try HookInput.decode(Data(#"{"session_id":"x","effort":"high"}"#.utf8)).raw["effort"], .string("high"))
    }
    func testWrongTypedOptionalFieldBecomesNilNotThrow() throws {
        XCTAssertNil(try HookInput.decode(Data(#"{"session_id":"x","cwd":5}"#.utf8)).cwd)
    }
}
