import Foundation

/// Claude plan usage written by the statusLine script to ~/.agentdeck/usage.json.
public struct UsageSnapshot: Decodable, Equatable {
    public struct Window: Decodable, Equatable {
        public var usedPercentage: Double
        public var resetsAt: Double
        public init(usedPercentage: Double, resetsAt: Double) { self.usedPercentage = usedPercentage; self.resetsAt = resetsAt }
        enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
    }
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var updatedAt: Double
    public init(fiveHour: Window?, sevenDay: Window? = nil, updatedAt: Double) {
        self.fiveHour = fiveHour; self.sevenDay = sevenDay; self.updatedAt = updatedAt
    }
    enum CodingKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day", updatedAt = "updated_at" }

    public static func parse(_ data: Data?) -> UsageSnapshot? {
        data.flatMap { try? JSONDecoder().decode(UsageSnapshot.self, from: $0) }
    }
}

public let usageStaleAge: TimeInterval = 600

public func usageLabel(_ s: UsageSnapshot?, now: Date) -> (text: String, stale: Bool)? {
    guard let w = s?.fiveHour, let s else { return nil }
    let reset = Date(timeIntervalSince1970: w.resetsAt)
    let passed = reset <= now
    let stale = passed || now.timeIntervalSince1970 - s.updatedAt > usageStaleAge
    if passed { return ("5h — · reset", stale) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
    return ("5h \(Int(w.usedPercentage.rounded(.down)))% · \(f.string(from: reset))", stale)
}

/// "5h 58% · 14:40" -> "Claude plan usage 58 percent, resets 14:40"; the reset form reads "window reset".
public func usageAccessibility(_ text: String) -> String {
    let p = text.components(separatedBy: " · ")
    guard p.count == 2, let pct = p[0].split(separator: " ").last, pct.hasSuffix("%") else { return "Claude plan usage window reset" }
    return "Claude plan usage \(pct.dropLast()) percent, resets \(p[1])"
}
