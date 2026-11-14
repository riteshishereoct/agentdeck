import XCTest
@testable import AgentDeckCore

/// Plan-validation S4 / amendment A4: an unknown or absent permission_mode never holds; it passes with one notice.
final class PermissionModeTests: XCTestCase {
    private func input(_ tool: String, _ toolInput: [String: Any], mode: String?) -> HookInput {
        var f: [String: Any] = ["session_id": "s1", "cwd": "/p", "tool_name": tool, "tool_input": toolInput]
        if let mode { f["permission_mode"] = mode }
        return try! HookInput.decode(JSONSerialization.data(withJSONObject: f))
    }
    private let modes: [String?] = ["weird", nil]
    private let edit = ["file_path": "/p/a.swift"]

    func testGateEndpointOnGateCategory() {
        for mode in modes {
            for (tool, body) in [("Bash", ["command": "npm install"]), ("Edit", edit)] {
                let h = Harness([.Bash: .gate, .EditWrite: .gate]); h.away()
                XCTAssertEqual(h.broker.gate(input(tool, body, mode: mode), meta: ui), .pass, "\(tool) \(mode ?? "nil")")
                XCTAssertEqual(h.broker.pending.map(\.channel), [.notify], "\(tool) \(mode ?? "nil")")
                XCTAssertEqual(h.held.map(\.channel), [.notify])
            }
        }
    }
    func testDecideEndpointOnRaceCategory() {
        for mode in modes {
            for (tool, body) in [("Bash", ["command": "npm install"]), ("Edit", edit)] {
                let h = Harness([.Bash: .race, .EditWrite: .race])
                XCTAssertEqual(h.broker.decide(input(tool, body, mode: mode), meta: ui), .pass, "\(tool) \(mode ?? "nil")")
                XCTAssertEqual(h.broker.pending.map(\.channel), [.notify], "\(tool) \(mode ?? "nil")")
            }
        }
    }
    func testWrongEndpointForTheChannelNeverHolds() {
        for mode in modes {
            let race = Harness([.Bash: .race]); race.away()           // PreToolUse on a race tool: nothing to gate
            XCTAssertEqual(race.broker.gate(input("Bash", ["command": "npm install"], mode: mode), meta: ui), .pass)
            XCTAssertTrue(race.broker.pending.isEmpty)
            let gate = Harness([.Bash: .gate])                         // PermissionRequest on a gate tool: native prompt is showing
            XCTAssertEqual(gate.broker.decide(input("Bash", ["command": "npm install"], mode: mode), meta: ui), .pass)
            XCTAssertEqual(gate.broker.pending.map(\.channel), [.notify])
        }
    }
    func testOverTheRealSocket() throws {
        let h = try DaemonHarness(categories: ["Bash": 1])
        defer { h.stop() }
        let seen = PendingSeen(); h.daemon.onChange = { seen.add($0) }
        var weird = bashBody; weird["permission_mode"] = "weird"
        var absent = bashBody; absent["permission_mode"] = nil; absent["session_id"] = "s2"
        XCTAssertEqual(h.post("/v1/decide/PermissionRequest", weird), "PASS")
        XCTAssertEqual(h.post("/v1/decide/PermissionRequest", absent), "PASS")
        let end = Date().addingTimeInterval(3)
        while seen.pending.count < 2 && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(seen.pending.count, 2); XCTAssertTrue(seen.pending.values.allSatisfy { $0.channel == .notify })
    }
}
