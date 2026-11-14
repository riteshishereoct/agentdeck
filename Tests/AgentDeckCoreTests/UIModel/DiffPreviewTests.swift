import XCTest
@testable import AgentDeckCore

final class DiffPreviewTests: XCTestCase {
    func testEditShowsRemovedThenAddedLinesWithSixLineLimit() {
        let input: JSONValue = .object(["old_string": .string("old\nline"), "new_string": .string("new\n1\n2\n3\n4\n5\n6")])
        let d = CardFormat.diffPreview(tool: "Edit", input: input)
        XCTAssertEqual(d?.text, "− old\n− line\n+ new\n+ 1\n+ 2\n+ 3\n+ 4\n+ 5\n+ … 1 more line not shown"); XCTAssertEqual(d?.omitted, true)
        XCTAssertNil(CardFormat.diffPreview(tool: "Bash", input: input))
    }
    func testWriteMasksCredentialsBeforePreviewAndNeverReadsDisk() {
        let input: JSONValue = .object(["file_path": .string("/nonexistent/private.txt"), "content": .string("token sk-abcdefghijklmnopqrstuv")])
        XCTAssertEqual(CardFormat.diffPreview(tool: "Write", input: input)?.text, "+ token sk-a••••")
        XCTAssertEqual(CardFormat.diffPreview(tool: "Write", input: input)?.omitted, false)
        XCTAssertNil(CardFormat.diffPreview(tool: "Edit", input: .object([:])))
    }
    // H1: a huge old_string must not eat the budget for the new text, and dropped edits are counted.
    func testOldAndNewHaveSeparateBudgetsAndDroppedEditsAreCounted() {
        let big = (1...10).map { "o\($0)" }.joined(separator: "\n")
        let d = CardFormat.diffPreview(tool: "Edit", input: .object(["old_string": .string(big), "new_string": .string("n1\nn2")]), maxLines: 3)
        XCTAssertEqual(d?.text, "− o1\n− o2\n− o3\n− … 7 more lines not shown\n+ n1\n+ n2")
        let edit: JSONValue = .object(["old_string": .string("a\nb"), "new_string": .string("c\nd")])
        let m = CardFormat.diffPreview(tool: "MultiEdit", input: .object(["edits": .array([edit, edit, edit, edit])]), maxLines: 3)
        XCTAssertEqual(m?.text, "− a\n− b\n+ c\n+ d\n− a\n− … 1 more line not shown\n+ c\n+ … 1 more line not shown\n… 2 more edits not shown")
        XCTAssertEqual(m?.omitted, true)
    }
}
