import Foundation

public enum ThemeAppearance: String, Codable, Sendable, CaseIterable { case system, light, dark }
public enum ThemeSurface: String, Codable, Sendable, CaseIterable { case liquidGlass, frosted, solid }
public enum ThemeAccent: String, Codable, Sendable, CaseIterable { case system, ocean, forest, sunset, grape, graphite }

public enum ThemeFormat {
    public static let opacityRange: ClosedRange<Double> = 0.35...1.0
    public static let defaultOpacity: Double = 0.82
    /// NaN falls back to the default; everything else is pinned into the range.
    public static func clampOpacity(_ v: Double) -> Double {
        v.isNaN ? defaultOpacity : min(max(v, opacityRange.lowerBound), opacityRange.upperBound)
    }
}
