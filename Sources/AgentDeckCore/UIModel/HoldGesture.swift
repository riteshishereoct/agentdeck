import Foundation

public struct HoldGesture {
    public static let duration: TimeInterval = 1.0
    private let clock: Clock
    private var startedAt: Date?
    public private(set) var requestId: String?
    public init(clock: Clock) { self.clock = clock }

    public mutating func begin(requestId: String) { self.requestId = requestId; startedAt = clock.now() }
    public mutating func cancel() { requestId = nil; startedAt = nil }
    public func progress() -> Double {
        guard let s = startedAt else { return 0 }
        return min(1, max(0, clock.now().timeIntervalSince(s) / Self.duration))
    }
    /// The id if held for the full duration (then resets); otherwise nil and resets.
    public mutating func complete() -> String? {
        defer { cancel() }
        guard let id = requestId, let s = startedAt, clock.now().timeIntervalSince(s) >= Self.duration - 0.000_001 else { return nil }
        return id
    }
}

public enum StatusText {
    public static func text(for status: RequestStatus) -> String? {
        switch status {
        case .handledElsewhere: return "Handled elsewhere"
        case .movedToCursor: return "Moved to Cursor ↗"
        case .timedOut: return "waiting in Cursor ↗"
        default: return nil
        }
    }
}
