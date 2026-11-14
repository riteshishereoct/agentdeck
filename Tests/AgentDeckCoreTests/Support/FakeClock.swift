import Foundation
@testable import AgentDeckCore

final class FakeClock: Clock, @unchecked Sendable {
    var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    func now() -> Date { current }
    func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}
