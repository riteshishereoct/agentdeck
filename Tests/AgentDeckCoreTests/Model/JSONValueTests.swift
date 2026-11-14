import XCTest
@testable import AgentDeckCore

final class JSONValueTests: XCTestCase {
    func testDecodeEncodeRoundTrip() throws {
        let src = #"{"a":[1,2.5,"x",null,true],"b":{"c":"d"}}"#
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(src.utf8))
        XCTAssertEqual(v["b"]?["c"]?.stringValue, "d")
        XCTAssertEqual(v["a"], .array([.number(1), .number(2.5), .string("x"), .null, .bool(true)]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v)), v)
    }
    func testSubscriptAndStringValueAreNilOffObjectsAndStrings() {
        XCTAssertNil(JSONValue.string("x")["k"]); XCTAssertNil(JSONValue.object([:])["k"])
        XCTAssertNil(JSONValue.number(1).stringValue); XCTAssertEqual(JSONValue.string("x").stringValue, "x")
    }
    func testCompactDataIsCompactAndParsesBack() throws {
        let v = JSONValue.object(["k": .array([.number(1), .string("a/b")]), "z": .null])
        let s = String(decoding: try v.compactData(), as: UTF8.self)
        XCTAssertFalse(s.contains(" ")); XCTAssertFalse(s.contains("\n"))
        XCTAssertTrue(s.contains("a/b"))   // slashes not escaped
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(s.utf8)), v)
    }
    func testFakeClockAdvancesAndSystemClockIsNow() {
        let c = FakeClock(); let t = c.now(); c.advance(30)
        XCTAssertEqual(c.now().timeIntervalSince(t), 30, accuracy: 0.0001)
        XCTAssertEqual(SystemClock().now().timeIntervalSinceNow, 0, accuracy: 1)
    }
}
