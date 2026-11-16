import XCTest
@testable import AgentDeckCore

final class AboutInfoTests: XCTestCase {
    func testMenuCatalogCoversEveryTitleWithoutDuplicates() {
        let titles = ["Show", "Hide", "Away mode", "Quiet", "Privacy", "Pause AgentDeck", "Settings…", "Setup & Help…",
                      "Install or repair hooks…", "Reload capabilities", "About AgentDeck", "Quit"]
        for t in titles { XCTAssertNotNil(MenuCatalog.symbol(for: t), t) }
        XCTAssertEqual(MenuCatalog.symbols.count, titles.count)
        XCTAssertEqual(Set(MenuCatalog.symbols.map(\.title)).count, MenuCatalog.symbols.count)
        XCTAssertEqual(Set(MenuCatalog.symbols.map(\.symbol)).count, MenuCatalog.symbols.count)
    }
    func testVersionLine() {
        func line(_ d: [String: Any]?) -> String { AboutInfo(info: d, hooks: "", socketPath: "", home: "/h").versionLine }
        XCTAssertEqual(line(["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "3"]), "Version 0.2.0 (build 3)")
        XCTAssertEqual(line(["CFBundleShortVersionString": "0.2.0"]), "Version 0.2.0")
        XCTAssertEqual(line(nil), "Development build (no bundle)")
    }
    func testTildeAbbreviation() {
        XCTAssertEqual(AboutInfo.abbreviate("/Users/a/Library/x.sock", home: "/Users/a"), "~/Library/x.sock")
        XCTAssertEqual(AboutInfo.abbreviate("/Users/ab/x", home: "/Users/a"), "/Users/ab/x")
        XCTAssertEqual(AboutInfo.abbreviate("/tmp/x", home: ""), "/tmp/x")
    }
    func testHooksSummary() {
        XCTAssertEqual(AboutInfo.hooksSummary(sessions: 0, degraded: 0), "No active sessions")
        XCTAssertEqual(AboutInfo.hooksSummary(sessions: 1, degraded: 0), "Healthy (1 session)")
        XCTAssertEqual(AboutInfo.hooksSummary(sessions: 3, degraded: 2), "2 of 3 need attention")
    }
    func testDetailsBlock() {
        let i = AboutInfo(info: nil, hooks: "Healthy (2 sessions)", socketPath: "/Users/a/s.sock", home: "/Users/a")
        XCTAssertTrue(i.details.contains("Socket: ~/s.sock"))
        XCTAssertTrue(i.details.contains("Hooks: Healthy (2 sessions)"))
        XCTAssertTrue(i.details.hasPrefix("AgentDeck\nDevelopment build"))
    }
}
