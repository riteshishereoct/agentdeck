import XCTest
@testable import AgentDeckCore

final class MetaLogTests: XCTestCase {
    func testRotatesToDotOneAtMaxBytesAndKeepsOnlyOneBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adk-log-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("agentdeck.log"); let log = MetaLog(url: url, maxBytes: 100)
        let line = String(repeating: "x", count: 29)   // 30 bytes with the newline
        for _ in 0..<6 { log.write(line) }
        let size = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? -1 }
        XCTAssertEqual(size(url.appendingPathExtension("1")), 120)   // 4 lines reached ≥ 100, so the 5th write rotated
        XCTAssertEqual(size(url), 60)
        for _ in 0..<20 { log.write(line) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("1").appendingPathExtension("1").path))
    }
}
