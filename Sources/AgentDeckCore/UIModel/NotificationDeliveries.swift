import Foundation

public struct NotificationDelivery: Equatable {
    public let requestId: String
    public let identifier: String
    let generation: Int
}

/// Tracks physical deliveries separately from request ids so an old callback cannot remove a privacy replacement.
public struct NotificationDeliveries {
    public private(set) var generation = 0
    private var activeIds = Set<String>()
    private var posted: [String: String] = [:]
    public init() {}

    public mutating func synchronize(activeIds: Set<String>, reset: Bool = false) -> [String] {
        self.activeIds = activeIds
        if reset { generation += 1 }
        let removed = posted.filter { reset || !activeIds.contains($0.key) }
        for key in removed.keys { posted[key] = nil }
        return removed.values.sorted()
    }

    public mutating func begin(requestId: String, expectedGeneration: Int) -> NotificationDelivery? {
        guard generation == expectedGeneration, activeIds.contains(requestId) else { return nil }
        let delivery = NotificationDelivery(requestId: requestId, identifier: "\(requestId).\(generation)", generation: generation)
        posted[requestId] = delivery.identifier
        return delivery
    }

    /// Returns only this delivery's id when the OS should remove it. A replacement's bookkeeping is preserved.
    public mutating func finish(_ delivery: NotificationDelivery, failed: Bool) -> String? {
        let current = posted[delivery.requestId] == delivery.identifier
        let remove = failed || !current || delivery.generation != generation || !activeIds.contains(delivery.requestId)
        if remove, current { posted[delivery.requestId] = nil }
        return remove ? delivery.identifier : nil
    }
}
