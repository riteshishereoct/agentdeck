import Foundation
import CoreGraphics

public enum SnapGeometry {
    public static let threshold: CGFloat = 40
    public static let margin: CGFloat = 8

    /// AppKit coordinates (y up). Snaps to the nearest corner of `visible.insetBy(margin)` when BOTH edge gaps to that corner are <= threshold; else returns `frame` unchanged.
    public static func snap(_ frame: CGRect, in visible: CGRect) -> CGRect {
        let inner = visible.insetBy(dx: margin, dy: margin)
        var best: (cost: CGFloat, origin: CGPoint)?
        for right in [false, true] {
            for top in [false, true] {
                let dx = abs(right ? inner.maxX - frame.maxX : frame.minX - inner.minX)
                let dy = abs(top ? inner.maxY - frame.maxY : frame.minY - inner.minY)
                guard dx <= threshold, dy <= threshold, best == nil || dx + dy < best!.cost else { continue }
                best = (dx + dy, CGPoint(x: right ? inner.maxX - frame.width : inner.minX,
                                         y: top ? inner.maxY - frame.height : inner.minY))
            }
        }
        guard let b = best else { return frame }
        return CGRect(origin: b.origin, size: frame.size)
    }

    /// Resize keeping the top edge and the horizontal side nearest the screen centre line (right edge if frame.midX > visible.midX, else left edge); result clamped inside `visible`.
    /// Shift upward when needed to keep the requested height; shrink only to fit the whole display.
    public static func resized(_ frame: CGRect, to size: CGSize, in visible: CGRect) -> CGRect {
        let w = min(max(0, size.width), max(0, visible.width))
        let h = min(max(0, size.height), max(0, visible.height))
        let top = min(max(frame.maxY, visible.minY + h), visible.maxY)
        var x = frame.midX > visible.midX ? frame.maxX - w : frame.minX
        x = min(max(x, visible.minX), visible.maxX - w)
        return CGRect(x: x, y: top - h, width: w, height: h)
    }

    public static func defaultFrame(size: CGSize, in visible: CGRect) -> CGRect {
        let inner = visible.insetBy(dx: margin, dy: margin)
        return CGRect(x: inner.maxX - size.width, y: inner.maxY - size.height, width: size.width, height: size.height)
    }

    public static func displayKey(_ id: UInt32) -> String { "display-\(id)" }
}

public struct FrameStore {
    public static let key = "OverlayFrames"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load(displayKey: String) -> CGRect? {
        guard let a = (defaults.dictionary(forKey: Self.key) as? [String: [Double]])?[displayKey], a.count == 4 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    public func save(_ frame: CGRect, displayKey: String) {
        var all = (defaults.dictionary(forKey: Self.key) as? [String: [Double]]) ?? [:]
        all[displayKey] = [frame.origin.x, frame.origin.y, frame.width, frame.height].map(Double.init)
        defaults.set(all, forKey: Self.key)
    }

    public func loadAnchorRight(displayKey: String) -> Bool? {
        (defaults.dictionary(forKey: "OverlayAnchorSides") as? [String: Bool])?[displayKey]
    }

    public func saveAnchorRight(_ right: Bool, displayKey: String) {
        var sides = defaults.dictionary(forKey: "OverlayAnchorSides") as? [String: Bool] ?? [:]
        sides[displayKey] = right
        defaults.set(sides, forKey: "OverlayAnchorSides")
    }
}

public enum CardViewport {
    public static func fullyVisible(_ card: CGRect, in viewport: CGRect) -> Bool {
        card.width > 0 && card.height > 0 && viewport.contains(card)
    }
}
