import XCTest
@testable import AgentDeckCore

final class SettingsStoreTests: XCTestCase {
    private func make() -> (SettingsStore, UserDefaults, String) {
        let name = "adk.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: d), d, name)
    }
    func testMissingGivesDefaults() {
        let (s, d, n) = make(); defer { d.removePersistentDomain(forName: n) }
        XCTAssertEqual(s.load(), AppSettings())
    }
    func testRoundTripUsesKeyAppSettings() {
        let (s, d, n) = make(); defer { d.removePersistentDomain(forName: n) }
        var a = AppSettings(); a.quiet = true; a.awayThresholdSeconds = 45; a.gateScope = .riskyOnly; a.cursorBundleIds = ["x.y"]
        s.save(a)
        XCTAssertNotNil(d.data(forKey: "AppSettings"))
        XCTAssertEqual(s.load(), a)
    }
    func testCorruptJSONGivesDefaults() {
        let (s, d, n) = make(); defer { d.removePersistentDomain(forName: n) }
        d.set(Data("{nope".utf8), forKey: "AppSettings")
        XCTAssertEqual(s.load(), AppSettings())
    }
    func testWrongTypeGivesDefaults() {
        let (s, d, n) = make(); defer { d.removePersistentDomain(forName: n) }
        d.set("a string", forKey: "AppSettings")
        XCTAssertEqual(s.load(), AppSettings())
    }
    func testDefaultsMatchContract() {
        let a = AppSettings()
        XCTAssertEqual(a.awayThresholdSeconds, 20)
        XCTAssertEqual(a.cursorBundleIds, ["com.todesktop.230313mzl4w4u92"])
        XCTAssertEqual(a.gateScope, .automatic)
        XCTAssertFalse(a.summarizer); XCTAssertTrue(a.sounds)
    }
    func testHideWhenIdleDefaultsOnAndOldBlobKeepsIt() throws {
        XCTAssertTrue(AppSettings().hideWhenIdle)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"quiet":true}"#.utf8))
        XCTAssertTrue(old.hideWhenIdle); XCTAssertTrue(old.quiet)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"hideWhenIdle":false}"#.utf8))
        XCTAssertFalse(off.hideWhenIdle)
        var a = AppSettings(); a.hideWhenIdle = false
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(a)), a)
    }
}
