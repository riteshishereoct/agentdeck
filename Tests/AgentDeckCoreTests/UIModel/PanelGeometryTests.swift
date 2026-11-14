import XCTest
@testable import AgentDeckCore

final class PanelGeometryTests: XCTestCase {
    func testChosenRightSideSurvivesNearCentreBox() {
        let visible = CGRect(x: 0, y: 0, width: 1800, height: 1100)
        let pill = CGRect(x: 900, y: 1000, width: 200, height: 31)
        let box = PanelGeometry.userBox(shown: pill, user: CGSize(width: 440, height: 600), in: visible, right: true)
        let restored = PanelGeometry.anchored(pill.size, top: CGPoint(x: box.maxX, y: box.maxY), right: true, in: visible)
        XCTAssertEqual(restored, pill, "the expanded box midpoint must not reverse the chosen side")
    }

    func testFrameStoreRetainsExplicitAnchorSide() {
        let name = "adk.anchor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!; defer { defaults.removePersistentDomain(forName: name) }
        let store = FrameStore(defaults: defaults)
        XCTAssertNil(store.loadAnchorRight(displayKey: "display-1"))
        store.saveAnchorRight(true, displayKey: "display-1")
        XCTAssertEqual(store.loadAnchorRight(displayKey: "display-1"), true)
        store.saveAnchorRight(false, displayKey: "display-1")
        XCTAssertEqual(store.loadAnchorRight(displayKey: "display-1"), false)
    }
    let v = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testClampKeepsMinimumAndDisplayMaximum() {
        XCTAssertEqual(PanelGeometry.clamp(CGSize(width: 100, height: 50), in: v), PanelGeometry.minSize)
        XCTAssertEqual(PanelGeometry.clamp(CGSize(width: 5000, height: 5000), in: v), CGSize(width: 1424, height: 884))
        XCTAssertEqual(PanelGeometry.clamp(CGSize(width: 500, height: 400), in: v), CGSize(width: 500, height: 400))
    }
    func testTinyDisplayMaximumWinsOverMinimum() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 120)
        XCTAssertEqual(PanelGeometry.clamp(CGSize(width: 440, height: 400), in: tiny), CGSize(width: 284, height: 104))
    }
    func testRestoredSizeDefaultsAndClamps() {
        XCTAssertEqual(PanelGeometry.restoredSize(nil, in: v), CGSize(width: 440, height: 884))   // shrink-to-fit up to the display
        XCTAssertEqual(PanelGeometry.restoredSize(CGSize(width: 600, height: 300), in: v), CGSize(width: 600, height: 320))
    }
    func testScaleChange2xTo1xClampsSavedBoxIntoSmallerPointSpace() {
        // Saved on "looks like 2560x1440"; the same panel now reports 1280x800 points.
        let small = CGRect(x: 0, y: 0, width: 1280, height: 775)
        let saved = CGRect(x: 1400, y: 300, width: 1500, height: 1000)
        let size = PanelGeometry.restoredSize(saved.size, in: small)
        XCTAssertEqual(size, CGSize(width: 1264, height: 759))
        let f = PanelGeometry.anchored(size, top: CGPoint(x: saved.maxX, y: saved.maxY), right: true, in: small)
        XCTAssertTrue(small.contains(f), "\(f) must be on screen")
    }
    func testDisplayRemovedPicksNearestScreen() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(PanelGeometry.nearest(to: CGRect(x: 100, y: 100, width: 300, height: 200), in: [left, v, right]), 1)   // contains centre
        XCTAssertEqual(PanelGeometry.nearest(to: CGRect(x: 3500, y: 500, width: 300, height: 200), in: [left, v]), 1)       // old right display gone
        XCTAssertEqual(PanelGeometry.nearest(to: CGRect(x: -3000, y: 500, width: 300, height: 200), in: [left, v]), 0)
        XCTAssertNil(PanelGeometry.nearest(to: .zero, in: []))
    }
    func testAnchoredKeepsTopCornerAndClampsOnScreen() {
        let r = PanelGeometry.anchored(CGSize(width: 400, height: 300), top: CGPoint(x: 1432, y: 892), right: true, in: v)
        XCTAssertEqual(r, CGRect(x: 1032, y: 592, width: 400, height: 300))
        let l = PanelGeometry.anchored(CGSize(width: 400, height: 300), top: CGPoint(x: 8, y: 892), right: false, in: v)
        XCTAssertEqual(l, CGRect(x: 8, y: 592, width: 400, height: 300))
        let off = PanelGeometry.anchored(CGSize(width: 400, height: 300), top: CGPoint(x: 1300, y: 100), right: false, in: v)
        XCTAssertTrue(v.contains(off)); XCTAssertEqual(off.size, CGSize(width: 400, height: 300))
    }
    func testUserBoxKeepsTopEdgeAndNearSide() {
        let shownRight = CGRect(x: 1032, y: 700, width: 400, height: 192)
        XCTAssertEqual(PanelGeometry.userBox(shown: shownRight, user: CGSize(width: 400, height: 600), in: v),
                       CGRect(x: 1032, y: 292, width: 400, height: 600))
        let pill = CGRect(x: 8, y: 856, width: 150, height: 36)   // collapsed pill on the left keeps the user size
        XCTAssertEqual(PanelGeometry.userBox(shown: pill, user: CGSize(width: 400, height: 600), in: v),
                       CGRect(x: 8, y: 292, width: 400, height: 600))
    }
    func testGripDragRightGrowsWidthAndShrinksHeightCap() {
        let user = CGSize(width: 440, height: 884), shown = CGSize(width: 440, height: 300)
        // Screen y is up: dragging the bottom edge up by 100 is dy = +100.
        XCTAssertEqual(PanelGeometry.dragged(user: user, shown: shown, delta: CGVector(dx: 60, dy: 100), leftGrip: false, in: v),
                       CGSize(width: 500, height: 320))
        XCTAssertEqual(PanelGeometry.dragged(user: user, shown: shown, delta: CGVector(dx: 60, dy: 100), leftGrip: true, in: v),
                       CGSize(width: 380, height: 320))
    }
    func testWidthOnlyDragKeepsHeightCapAboveShortContent() {
        let user = CGSize(width: 440, height: 700), shown = CGSize(width: 440, height: 250)
        XCTAssertEqual(PanelGeometry.dragged(user: user, shown: shown, delta: CGVector(dx: 40, dy: 0), leftGrip: false, in: v).height, 700)
        XCTAssertEqual(PanelGeometry.dragged(user: user, shown: shown, delta: CGVector(dx: 0, dy: -900), leftGrip: false, in: v).height, 884)
    }
    func testGripDragRespectsMinimum() {
        let s = PanelGeometry.dragged(user: CGSize(width: 440, height: 400), shown: CGSize(width: 440, height: 400),
                                      delta: CGVector(dx: -1000, dy: 1000), leftGrip: false, in: v)
        XCTAssertEqual(s, PanelGeometry.minSize)
    }
    func testBoxKeyIsSeparateFromLegacyFrameKey() {
        XCTAssertEqual(PanelGeometry.boxKey("display-7"), "display-7.box")
    }
}
