import Foundation

public struct YourTurnCard: Equatable { public let sessionId: String; public let text: String; public let since: Date }
public struct YourTurnTracker {
    public static let foldAfter: TimeInterval = 10
    private let clock: Clock
    private var cards: [String: YourTurnCard] = [:]
    private var active = Set<String>()
    public init(clock: Clock) { self.clock = clock }
    public mutating func update(_ sessions: [Session]) {
        let turns = sessions.filter { $0.state == .yourTurn }
        let ids = Set(turns.map(\.id))
        cards = cards.filter { ids.contains($0.key) }
        for s in turns where !active.contains(s.id) {
            cards[s.id] = YourTurnCard(sessionId: s.id, text: s.summary ?? "Done", since: clock.now())
        }
        for s in turns {
            if let card = cards[s.id], let summary = s.summary {
                cards[s.id] = YourTurnCard(sessionId: s.id, text: summary, since: card.since)
            }
        }
        active = ids
    }
    public mutating func dismiss(sessionId: String) { cards.removeValue(forKey: sessionId) }
    public func visible() -> [YourTurnCard] {
        cards.values.filter { clock.now().timeIntervalSince($0.since) < Self.foldAfter }
            .sorted { ($0.since, $0.sessionId) < ($1.since, $1.sessionId) }
    }
}
