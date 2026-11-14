import XCTest
@testable import AgentDeckCore

final class CapabilityMatrixTests: XCTestCase {
    private var dir: URL!
    private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-cap-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func load(_ json: String) -> CapabilityMatrix {
        let url = dir.appendingPathComponent("capabilities.json")
        try! json.write(to: url, atomically: true, encoding: .utf8)
        return CapabilityMatrix.load(from: url)
    }
    private func doc(_ cats: String, version: String = "1", link: String = "\"cursor://x/open?s={session}\"") -> String {
        "{\"version\":\(version),\"extensionVersion\":\"2.1.323\",\"measuredAt\":null,\"deepLink\":\(link),\"categories\":{\(cats)}}"
    }

    func testMissingFileIsAllNotify() {
        let m = CapabilityMatrix.load(from: dir.appendingPathComponent("nope.json"))
        XCTAssertEqual(m, .fallback)
        for c in ToolCategory.allCases { XCTAssertEqual(m.channels[c], .notify, "\(c)") }
        XCTAssertEqual(m.deepLinkTemplate, CapabilityMatrix.defaultDeepLink)
    }
    func testValidValuesLoad() {
        let m = load(doc("\"Bash\":1,\"EditWrite\":2,\"Web\":3,\"MCP\":2,\"Question\":2,\"ExitPlanMode\":3,\"Other\":1"))
        XCTAssertEqual(m.channels[.Bash], .race); XCTAssertEqual(m.channels[.EditWrite], .gate)
        XCTAssertEqual(m.channels[.Web], .notify); XCTAssertEqual(m.channels[.MCP], .gate)
        XCTAssertEqual(m.channels[.Question], .gate); XCTAssertEqual(m.channels[.ExitPlanMode], .notify)
        XCTAssertEqual(m.channels[.Other], .race)
        XCTAssertEqual(m.deepLinkTemplate, "cursor://x/open?s={session}")
    }
    func testQuestionChannel1IsNotify() { XCTAssertEqual(load(doc("\"Question\":1")).channels[.Question], .notify) }
    func testExitPlanModeChannel2IsNotify() { XCTAssertEqual(load(doc("\"ExitPlanMode\":2")).channels[.ExitPlanMode], .notify) }
    func testVersion2IsAllNotify() { XCTAssertEqual(load(doc("\"Bash\":1", version: "2")), .fallback) }
    func testStringBooleanAndFractionalValuesAreNotify() {
        let m = load(doc("\"Bash\":\"1\",\"Web\":true,\"MCP\":1.5,\"EditWrite\":2"))
        XCTAssertEqual(m.channels[.Bash], .notify); XCTAssertEqual(m.channels[.Web], .notify)
        XCTAssertEqual(m.channels[.MCP], .notify); XCTAssertEqual(m.channels[.EditWrite], .gate)
    }
    func testMissingKeyAndBadValueAreNotify() {
        let m = load(doc("\"Bash\":1,\"Other\":7"))
        XCTAssertEqual(m.channels[.MCP], .notify); XCTAssertEqual(m.channels[.Other], .notify)
    }
    func testInvalidJSONAndNonObjectRootAreFallback() {
        XCTAssertEqual(load("not json"), .fallback)
        XCTAssertEqual(load("[]"), .fallback)
    }
    func testToolMapping() {
        for t in ["Edit", "Write", "MultiEdit", "NotebookEdit"] { XCTAssertEqual(CapabilityMatrix.category(forTool: t), .EditWrite, t) }
        XCTAssertEqual(CapabilityMatrix.category(forTool: "Bash"), .Bash)
        XCTAssertEqual(CapabilityMatrix.category(forTool: "mcp__github__create_issue"), .MCP)
        XCTAssertEqual(CapabilityMatrix.category(forTool: "WebSearch"), .Web)
        XCTAssertEqual(CapabilityMatrix.category(forTool: "WebFetch"), .Web)
        XCTAssertEqual(CapabilityMatrix.category(forTool: "AskUserQuestion"), .Question)
        XCTAssertEqual(CapabilityMatrix.category(forTool: "ExitPlanMode"), .ExitPlanMode)
        XCTAssertEqual(CapabilityMatrix.category(forTool: "Glob"), .Other)
        XCTAssertEqual(load(doc("\"Bash\":1")).channel(forTool: "Bash"), .race)
        XCTAssertEqual(load(doc("\"Bash\":1")).channel(forTool: "Glob"), .notify)
    }
    func testDeepLinkPercentEncodesSessionId() {
        XCTAssertEqual(CapabilityMatrix.fallback.deepLink(sessionId: "a b&c/ü").absoluteString,
                       "cursor://anthropic.claude-code/open?session=a%20b%26c%2F%C3%BC")
    }
    func testTemplateWithoutPlaceholderOrNonStringUsesDefault() {
        XCTAssertEqual(load(doc("\"Bash\":1", link: "\"cursor://x/open\"")).deepLinkTemplate, CapabilityMatrix.defaultDeepLink)
        XCTAssertEqual(load(doc("\"Bash\":1", link: "5")).deepLinkTemplate, CapabilityMatrix.defaultDeepLink)
    }
    func testRepoDefaultFileIsValidAndMatchesLoader() throws {
        let url = repoRoot.appendingPathComponent("config/capabilities.json")
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(raw["version"] as? Int, 1)
        XCTAssertNotNil(raw["extensionVersion"] as? String)
        XCTAssertTrue(raw.keys.contains("measuredAt"))
        let cats = raw["categories"] as! [String: Int]
        XCTAssertEqual(Set(cats.keys), Set(ToolCategory.allCases.map(\.rawValue)))
        let m = CapabilityMatrix.load(from: url)
        for c in ToolCategory.allCases { XCTAssertEqual(m.channels[c]?.rawValue, cats[c.rawValue], "\(c)") }
        XCTAssertEqual(m.channels[.ExitPlanMode], .notify)
        XCTAssertNotEqual(m.channels[.Question], .race)
        XCTAssertTrue(m.deepLinkTemplate.contains("{session}"))
    }
}
