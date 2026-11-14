import Foundation

/// Not thread-safe: call on the core queue. The daemon drives `poll()` from its tick.
public final class TranscriptTailer {
    public static let maxLine = 262_144
    private static let chunk = 1_048_576

    private struct Tracked {
        var path: String
        var offset: UInt64 = 0
        var partial = Data()
        var skipping = false
        var tally = TaskTally()
        var lastPolledAt: Date?
    }

    private let emit: (AgentEvent) -> Void
    private var tracked: [String: Tracked] = [:]

    public init(emit: @escaping (AgentEvent) -> Void) { self.emit = emit }

    public func track(sessionId: String, path: String) {
        if tracked[sessionId]?.path == path { return }
        tracked[sessionId] = Tracked(path: path)
    }

    public func untrack(sessionId: String) { tracked[sessionId] = nil }

    public func isTracking(sessionId: String, path: String) -> Bool { tracked[sessionId]?.path == path }

    /// A hold in one session must not make every inactive transcript read at the broker's 10 Hz cadence.
    public func poll(now: Date, activeSessionIds: Set<String>) {
        for id in Array(tracked.keys) {
            if !activeSessionIds.contains(id), let last = tracked[id]?.lastPolledAt,
               now >= last, now.timeIntervalSince(last) < 1 { continue }
            tracked[id]?.lastPolledAt = now
            poll(id)
        }
    }

    public func poll() {
        for id in Array(tracked.keys) { poll(id) }
    }

    private func poll(_ id: String) {
        guard var t = tracked[id], let h = FileHandle(forReadingAtPath: t.path) else { return }   // missing file: retry next poll
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return }
        if size < t.offset { t.offset = 0; t.partial = Data(); t.skipping = false; t.tally = TaskTally() }
        if size > t.offset, (try? h.seek(toOffset: t.offset)) != nil, let read = try? h.read(upToCount: Self.chunk), !read.isEmpty {
            t.offset += UInt64(read.count)
            var buf = t.partial + read
            if t.skipping {
                if let nl = buf.firstIndex(of: 10) { buf = Data(buf[(nl + 1)...]); t.skipping = false } else { buf = Data() }
            }
            var start = buf.startIndex
            while let nl = buf[start...].firstIndex(of: 10) {
                let line = buf[start..<nl]; start = nl + 1
                if line.count > Self.maxLine { continue }
                for e in TranscriptParser.events(fromLine: Data(line), sessionId: id, now: Date(), tally: &t.tally) { emit(e) }
            }
            t.partial = Data(buf[start...])
            if t.partial.count > Self.maxLine { t.partial = Data(); t.skipping = true }
        }
        if tracked[id] != nil { tracked[id] = t }   // emit may have untracked it
    }
}
