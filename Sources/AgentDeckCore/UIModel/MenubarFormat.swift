import Foundation

public enum MenubarFormat {
    public static func badge(pending: Int) -> String { pending <= 0 ? "" : pending > 9 ? "9+" : "\(pending)" }
}

public enum SettingsFormat {
    public static let awayRange: ClosedRange<Double> = 5...300
    public static func clampAway(_ v: Double) -> Double { min(awayRange.upperBound, max(awayRange.lowerBound, v)) }

    public static func parseBundleIds(_ text: String, fallback: [String]) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for p in text.components(separatedBy: CharacterSet(charactersIn: ",").union(.whitespacesAndNewlines)) where !p.isEmpty && seen.insert(p).inserted { out.append(p) }
        return out.isEmpty ? fallback : out
    }
}
