import XCTest
@testable import AgentDeckCore

final class StateEmojiTests: XCTestCase {
    private let all: [SessionState] = [.idle, .working, .needsYou, .waitingInCursor, .yourTurn, .error, .ended, .quiet]

    func testEveryStateMappedWithUniqueEmojiAndLabel() {
        let m = all.map { StateEmoji.for($0) }
        XCTAssertEqual(Set(m.map(\.emoji)).count, all.count)
        XCTAssertTrue(m.allSatisfy { !$0.emoji.isEmpty && !$0.label.isEmpty })
    }
    func testPillShowsMostUrgentLiveState() {
        XCTAssertEqual(StateEmoji.pillState([]), .idle)
        XCTAssertEqual(StateEmoji.pillState([UI.session("a", state: .working), UI.session("b", state: .needsYou)]), .needsYou)
        XCTAssertEqual(StateEmoji.pillState([UI.session("a", state: .working), UI.session("b", state: .error)]), .error)
        XCTAssertEqual(StateEmoji.pillState([UI.session("a", state: .ended), UI.session("b", state: .quiet)]), .idle)
    }
    func testOnlyWorkingAndNeedsYouLoop() {
        XCTAssertEqual(all.filter { StateEmoji.for($0).continuous }, [.working, .needsYou])
    }
    func testLoopPoseIsCappedAndPeriodic() {
        XCTAssertEqual(StateEmoji.loopInterval, 1.0 / 15.0, accuracy: 1e-9)
        XCTAssertEqual(StateEmoji.loopSeconds, CompanionPolicy.reactionSeconds)
        XCTAssertEqual(StateEmoji.loopPose(.spin, at: 0).angle, 0, accuracy: 1e-9)
        XCTAssertEqual(StateEmoji.loopPose(.spin, at: 1.2).angle, 180, accuracy: 1e-6)
        XCTAssertEqual(StateEmoji.loopPose(.spin, at: 2.4 + 0.6).angle, 90, accuracy: 1e-6)
        XCTAssertEqual(StateEmoji.loopPose(.pulse, at: 0).scale, 1, accuracy: 1e-9)
        XCTAssertEqual(StateEmoji.loopPose(.pulse, at: 0.8).scale, 1.2, accuracy: 1e-9)
        XCTAssertEqual(StateEmoji.loopPose(.bounce, at: 0.5).scale, 1, accuracy: 1e-9)
        XCTAssertEqual(StateEmoji.loopPose(.bounce, at: 0.5).angle, 0, accuracy: 1e-9)
    }
}
