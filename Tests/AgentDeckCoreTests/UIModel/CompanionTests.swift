import XCTest
@testable import AgentDeckCore

final class CompanionTests: XCTestCase {
    func testMoodMapping() {
        let m: [(SessionState, CompanionMood)] = [(.needsYou, .alert), (.error, .upset), (.yourTurn, .happy), (.working, .busy),
                                                  (.waitingInCursor, .calm), (.idle, .sleeping), (.quiet, .sleeping), (.ended, .sleeping)]
        for (s, e) in m { XCTAssertEqual(CompanionMood.from(state: s), e) }
        XCTAssertEqual(CompanionMood.from(sessions: []), .sleeping)
    }
    func testPolicyTruthTable() {
        for mood in CompanionMood.allCases { for hov in [false, true] { for since in [0.0, 3.9, 4.0, 100] {
            // Every tick re-renders the glass panel (~28% of a core measured), so no mood loops forever: only hover or a fresh change.
            let expect = hov || since < 4
            XCTAssertEqual(CompanionPolicy.shouldAnimate(style: .pet, mood: mood, visible: true, enabled: true, hovering: hov, secondsSinceMoodChange: since), expect)
            XCTAssertFalse(CompanionPolicy.shouldAnimate(style: .pet, mood: mood, visible: false, enabled: true, hovering: hov, secondsSinceMoodChange: since))
            XCTAssertFalse(CompanionPolicy.shouldAnimate(style: .geometry, mood: mood, visible: true, enabled: false, hovering: hov, secondsSinceMoodChange: since))
            XCTAssertFalse(CompanionPolicy.shouldAnimate(style: .off, mood: mood, visible: true, enabled: true, hovering: hov, secondsSinceMoodChange: since))
        } } }
        XCTAssertEqual(CompanionPolicy.frameInterval, 1.0 / 30.0)
        XCTAssertEqual(CompanionPolicy.frameInterval(for: .busy), 1.0 / 15.0)
        XCTAssertEqual(CompanionPolicy.frameInterval(for: .alert), 1.0 / 30.0)
    }
    func testStyleDecodeFallback() throws {
        func d(_ j: String) throws -> AppSettings { try JSONDecoder().decode(AppSettings.self, from: Data(j.utf8)) }
        XCTAssertEqual(try d("{}").companion, .pet)
        XCTAssertEqual(try d(#"{"companion":"geometry"}"#).companion, .geometry)
        let s = try d(#"{"companion":"hologram","quiet":true}"#)
        XCTAssertEqual(s.companion, .pet); XCTAssertTrue(s.quiet)
        XCTAssertEqual(try d(#"{"companion":5}"#).companion, .pet)
    }
}
