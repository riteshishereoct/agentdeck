import Foundation

public protocol SummarizerRunner { func run(prompt: String, completion: @escaping (String?) -> Void) }

/// Not thread-safe: call on the core queue. Off unless the daemon sets `enabled` from `settings.summarizer`; never in the decision path.
public final class Summarizer {
    public static let debounce: TimeInterval = 120
    public var enabled = false

    private struct Entry { var lastRun: Date; var cache: String?; var inFlight = true }
    private let runner: SummarizerRunner
    private let clock: Clock
    private var entries: [String: Entry] = [:]

    public init(runner: SummarizerRunner, clock: Clock) { self.runner = runner; self.clock = clock }

    public func request(session: Session, completion: @escaping (String?) -> Void) {
        guard enabled else { completion(nil); return }
        let now = clock.now()
        if let e = entries[session.id], e.inFlight || now.timeIntervalSince(e.lastRun) < Self.debounce { completion(e.cache); return }
        let cache = entries[session.id]?.cache
        entries[session.id] = Entry(lastRun: now, cache: cache)
        runner.run(prompt: Self.prompt(session)) { [weak self] out in
            let line = out?.split(whereSeparator: \.isNewline).first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(120)) }.flatMap { $0.isEmpty ? nil : $0 }
            self?.entries[session.id]?.inFlight = false
            if let line { self?.entries[session.id]?.cache = line }
            completion(line ?? cache)
        }
    }

    /// Goal, latest ask and last reply only: the step label and tool input never leave the machine.
    static func prompt(_ s: Session) -> String {
        var p = "Summarize in one line of at most 12 words what this coding session is doing. Reply with the line only."
        if let g = s.goal { p += "\nGoal: \(g)" }
        if let a = s.latestAsk { p += "\nLatest ask: \(a)" }
        if let r = s.summary { p += "\nLast reply: \(r)" }
        return p
    }
}
