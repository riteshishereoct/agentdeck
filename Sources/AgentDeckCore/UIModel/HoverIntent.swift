import Foundation

public struct HoverIntent {
    public static let expandDelay: TimeInterval = 0.3
    public static let collapseDelay: TimeInterval = 1.2
    private let clock: Clock
    private var insideSince: Date?
    private var outsideSince: Date?     // a fresh HoverIntent counts as outside since creation

    public init(clock: Clock) { self.clock = clock; outsideSince = clock.now() }

    /// Records enter / leave time; repeating the same value is a no-op.
    public mutating func pointer(inside: Bool) {
        if inside, insideSince == nil { insideSince = clock.now(); outsideSince = nil }
        if !inside, outsideSince == nil { outsideSince = clock.now(); insideSince = nil }
    }

    /// Desired expanded state. Collapsed -> true once the pointer has been inside >= 0.3 s.
    /// Expanded -> false once the pointer has been outside >= 1.2 s, unless pinned or hasPending.
    public func target(expanded: Bool, pinned: Bool, hasPending: Bool, enabled: Bool = true) -> Bool {
        guard enabled else { return expanded }
        let now = clock.now()
        if !expanded {
            guard let s = insideSince else { return false }
            return now.timeIntervalSince(s) >= Self.expandDelay - 0.000_001
        }
        if pinned || hasPending { return true }
        guard let s = outsideSince else { return true }
        return now.timeIntervalSince(s) < Self.collapseDelay - 0.000_001
    }
}

/// Movement cancels activation for the whole press, even if the pointer returns to its starting point.
public struct PillGesture {
    private var start: CGPoint?
    public private(set) var dragging = false
    public init() {}
    public mutating func begin(at point: CGPoint) { start = point; dragging = false }
    @discardableResult public mutating func move(to point: CGPoint) -> Bool {
        guard let start else { return false }
        if hypot(point.x - start.x, point.y - start.y) >= 4 { dragging = true }
        return dragging
    }
    public mutating func end() -> Bool {
        let click = start != nil && !dragging
        start = nil
        return click
    }
}
