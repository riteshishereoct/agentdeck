import Foundation
import CoreGraphics

/// Pure size/position math for the resizable expanded panel. AppKit coordinates (y up).
/// The user's "box" is the expanded size they chose; the shown panel is never taller than its content, so the box height is a cap.
public enum PanelGeometry {
    public static let minSize = CGSize(width: 320, height: 320)
    public static let defaultWidth: CGFloat = 440

    public static func maxSize(in visible: CGRect) -> CGSize {
        let m = SnapGeometry.margin * 2
        return CGSize(width: max(0, visible.width - m), height: max(0, visible.height - m))
    }

    /// Minimum first, then the display maximum, so a display smaller than the minimum still fits.
    public static func clamp(_ size: CGSize, in visible: CGRect) -> CGSize {
        let hi = maxSize(in: visible)
        return CGSize(width: min(max(size.width, minSize.width), hi.width), height: min(max(size.height, minSize.height), hi.height))
    }

    /// No saved box: the old behaviour, 440 wide and as tall as the display allows (content decides the shown height).
    public static func restoredSize(_ saved: CGSize?, in visible: CGRect) -> CGSize {
        clamp(saved ?? CGSize(width: defaultWidth, height: .greatestFiniteMagnitude), in: visible)
    }

    /// Frame of `size` hanging from `top` (its top-right corner if `right`, else top-left), shifted inside `visible`.
    public static func anchored(_ size: CGSize, top: CGPoint, right: Bool, in visible: CGRect) -> CGRect {
        let w = min(size.width, visible.width), h = min(size.height, visible.height)
        let x = min(max(right ? top.x - w : top.x, visible.minX), visible.maxX - w)
        let y = min(max(top.y - h, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// What is persisted per display: the user size hanging from the shown panel's top edge, on the side nearest the screen edge.
    public static func userBox(shown: CGRect, user: CGSize, in visible: CGRect, right: Bool? = nil) -> CGRect {
        let right = right ?? (shown.midX > visible.midX)
        return CGRect(x: right ? shown.maxX - user.width : shown.minX, y: shown.maxY - user.height, width: user.width, height: user.height)
    }

    /// New user size from a grip drag. `delta` is the pointer movement since mouse-down in screen points (y up).
    /// Width follows the grip; the height cap shrinks only when the panel visibly shrinks, and dragging past short content only raises it.
    public static func dragged(user: CGSize, shown: CGSize, delta: CGVector, leftGrip: Bool, in visible: CGRect) -> CGSize {
        let w = leftGrip ? shown.width - delta.dx : shown.width + delta.dx
        let h = shown.height - delta.dy
        return clamp(CGSize(width: w, height: h < shown.height ? h : max(user.height, h)), in: visible)
    }

    /// Index of the screen containing the frame's centre, else the one closest to it (display removed or rearranged).
    public static func nearest(to frame: CGRect, in screens: [CGRect]) -> Int? {
        let c = CGPoint(x: frame.midX, y: frame.midY)
        if let i = screens.firstIndex(where: { $0.contains(c) }) { return i }
        func d(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - c.x, 0, c.x - r.maxX), dy = max(r.minY - c.y, 0, c.y - r.maxY)
            return dx * dx + dy * dy
        }
        return screens.indices.min { d(screens[$0]) < d(screens[$1]) }
    }

    /// FrameStore key for the user box; the legacy key (shown frame) is read only as a position fallback.
    public static func boxKey(_ displayKey: String) -> String { displayKey + ".box" }
}
