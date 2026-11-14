import XCTest
@testable import AgentDeckCore

final class SnapGeometryTests: XCTestCase {
    let v = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let s = CGSize(width: 300, height: 60)
    func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(origin: CGPoint(x: x, y: y), size: s) }
    func testSnapsToAllFourCorners() {
        XCTAssertEqual(SnapGeometry.snap(rect(8 + 30, 8 + 30), in: v), rect(8, 8))                       // bottom-left
        XCTAssertEqual(SnapGeometry.snap(rect(1440 - 8 - 300 - 30, 8 + 30), in: v), rect(1440 - 308, 8)) // bottom-right
        XCTAssertEqual(SnapGeometry.snap(rect(8 + 30, 900 - 8 - 60 - 30), in: v), rect(8, 900 - 68))     // top-left
        XCTAssertEqual(SnapGeometry.snap(rect(1440 - 308 - 30, 900 - 68 - 30), in: v), rect(1440 - 308, 900 - 68)) // top-right
    }
    func testExactly40Snaps() { XCTAssertEqual(SnapGeometry.snap(rect(8 + 40, 8 + 40), in: v), rect(8, 8)) }
    func test41DoesNotSnap() {
        let f = rect(8 + 41, 8 + 41)
        XCTAssertEqual(SnapGeometry.snap(f, in: v), f)
    }
    func testOneAxisFarDoesNotSnap() {
        let f = rect(8 + 10, 400)
        XCTAssertEqual(SnapGeometry.snap(f, in: v), f)
    }
    func testSecondDisplayWithNegativeOrigin() {
        let v2 = CGRect(x: 1440, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(SnapGeometry.snap(rect(1440 + 8 + 20, -200 + 8 + 20), in: v2), rect(1440 + 8, -200 + 8))
        XCTAssertEqual(SnapGeometry.snap(rect(1440 + 8 + 20, -200 + 8 + 20), in: v), rect(1440 + 8 + 20, -200 + 8 + 20)) // not near any corner of display 1
    }
    func testResizeKeepsTopAndRightEdge() {
        let f = CGRect(x: 1440 - 308, y: 900 - 68, width: 300, height: 60)
        let r = SnapGeometry.resized(f, to: CGSize(width: 420, height: 300), in: v)
        XCTAssertEqual(r.maxX, f.maxX); XCTAssertEqual(r.maxY, f.maxY); XCTAssertEqual(r.size, CGSize(width: 420, height: 300))
    }
    func testResizeKeepsLeftEdgeOnLeftHalfAndClamps() {
        let f = CGRect(x: 8, y: 100, width: 300, height: 60)
        let r = SnapGeometry.resized(f, to: CGSize(width: 420, height: 300), in: v)
        XCTAssertEqual(r.minX, 8); XCTAssertEqual(r.height, 300); XCTAssertEqual(r.minY, 0)
    }
    func testDefaultFrameTopRight() { XCTAssertEqual(SnapGeometry.defaultFrame(size: s, in: v), rect(1440 - 308, 900 - 68)) }
    func testDisplayKey() { XCTAssertEqual(SnapGeometry.displayKey(69733890), "display-69733890") }
    func testFrameStoreRoundTripAndCorrupt() {
        let n = "adk.test.\(UUID().uuidString)"; let d = UserDefaults(suiteName: n)!; defer { d.removePersistentDomain(forName: n) }
        let st = FrameStore(defaults: d)
        XCTAssertNil(st.load(displayKey: "display-1"))
        st.save(rect(5, 6), displayKey: "display-1")
        XCTAssertEqual(st.load(displayKey: "display-1"), rect(5, 6))
        XCTAssertNil(st.load(displayKey: "display-2"))
        d.set("junk", forKey: "OverlayFrames")
        XCTAssertNil(st.load(displayKey: "display-1"))
    }
    func testOffscreenSavedFrameNeverProducesNegativeOrClippedCardHeight() {
        let frame = CGRect(x: 8, y: -400, width: 300, height: 60)
        let result = SnapGeometry.resized(frame, to: CGSize(width: 440, height: 500), in: v)
        XCTAssertEqual(result.height, 500)
        XCTAssertEqual(result.minY, 0)
        XCTAssertEqual(SnapGeometry.resized(frame, to: CGSize(width: 440, height: 2000), in: v).height, 900)
    }
    func testApprovalVisibilityRequiresTheWholeCardInsideViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 440, height: 500)
        XCTAssertTrue(CardViewport.fullyVisible(CGRect(x: 12, y: 30, width: 416, height: 200), in: viewport))
        XCTAssertFalse(CardViewport.fullyVisible(CGRect(x: 12, y: -20, width: 416, height: 200), in: viewport))
        XCTAssertFalse(CardViewport.fullyVisible(CGRect(x: 12, y: 30, width: 416, height: 600), in: viewport))
        XCTAssertFalse(CardViewport.fullyVisible(.zero, in: viewport))
    }

}
