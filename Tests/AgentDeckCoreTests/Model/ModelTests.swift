import XCTest
@testable import AgentDeckCore

final class ModelTests: XCTestCase {
    func testAppSettingsDefaultsMatchProtocol() {
        let s = AppSettings()
        XCTAssertEqual(s.cursorBundleIds, ["com.todesktop.230313mzl4w4u92"])
        XCTAssertFalse(s.gateOtherHosts); XCTAssertEqual(s.awayThresholdSeconds, 20); XCTAssertEqual(s.gateScope, .automatic)
        XCTAssertFalse(s.awayMode); XCTAssertFalse(s.quiet); XCTAssertFalse(s.privacy); XCTAssertFalse(s.paused)
        XCTAssertTrue(s.sounds); XCTAssertFalse(s.summarizer); XCTAssertFalse(s.launchAtLogin)
    }
    func testAppSettingsPartialJSONKeepsDefaultsAndRoundTrips() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"privacy":true,"gateScope":"riskyOnly"}"#.utf8))
        XCTAssertTrue(s.privacy); XCTAssertEqual(s.gateScope, .riskyOnly); XCTAssertEqual(s.awayThresholdSeconds, 20)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)), s)
    }
    func testGateVerbWireBody() {
        XCTAssertEqual(GateVerb.pass.wireBody, "PASS")
        XCTAssertEqual(GateVerb.hold(id: "AB-12").wireBody, "HOLD AB-12")
        XCTAssertEqual(GateVerb.decide(Data(#"{"a":1}"#.utf8)).wireBody, #"DECIDE {"a":1}"#)
    }
    func testRiskLevelOrdering() { XCTAssertTrue(RiskLevel.low < .med && RiskLevel.med < .high && !(RiskLevel.high < .low)) }
    func testSessionDefaultsAndFactories() {
        let s = Session(id: "s1", startedAt: Make.t0, lastEventAt: Make.t0)
        XCTAssertEqual(s.state, .idle); XCTAssertEqual(s.activity, Array(repeating: 0, count: 30))
        XCTAssertTrue(s.pending.isEmpty); XCTAssertNil(s.progress); XCTAssertFalse(s.hooksDegraded)
        let r = Make.request(); XCTAssertEqual(r.status, .pending); XCTAssertEqual(r.channel, .race)
        XCTAssertEqual(Make.event(.tick).ts, Make.t0)
        XCTAssertEqual(EventKind.hook(.stop), EventKind.hook(.stop))
        XCTAssertEqual(EventKind.transcriptTasks(TaskProgress(done: 1, total: 2)), .transcriptTasks(TaskProgress(done: 1, total: 2)))
    }
}
