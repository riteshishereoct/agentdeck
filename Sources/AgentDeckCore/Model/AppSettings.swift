import Foundation

public enum GateScope: String, Codable, Sendable { case automatic, full, riskyOnly }

public struct AppSettings: Codable, Equatable, Sendable {
    public var cursorBundleIds: [String] = ["com.todesktop.230313mzl4w4u92"]
    public var gateOtherHosts: Bool = false
    public var awayThresholdSeconds: Double = 20
    public var gateScope: GateScope = .automatic
    public var awayMode: Bool = false
    public var quiet: Bool = false
    public var privacy: Bool = false
    public var paused: Bool = false
    public var sounds: Bool = true
    public var summarizer: Bool = false
    public var launchAtLogin: Bool = false
    public var hideWhenIdle: Bool = true
    public var hoverToOpen: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case cursorBundleIds, gateOtherHosts, awayThresholdSeconds, gateScope, awayMode, quiet, privacy, paused
        case sounds, summarizer, launchAtLogin, hideWhenIdle, hoverToOpen
    }

    // Per-key decodeIfPresent so a blob saved by an older build never resets the other settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursorBundleIds = try c.decodeIfPresent([String].self, forKey: .cursorBundleIds) ?? cursorBundleIds
        gateOtherHosts = try c.decodeIfPresent(Bool.self, forKey: .gateOtherHosts) ?? gateOtherHosts
        awayThresholdSeconds = try c.decodeIfPresent(Double.self, forKey: .awayThresholdSeconds) ?? awayThresholdSeconds
        gateScope = try c.decodeIfPresent(GateScope.self, forKey: .gateScope) ?? gateScope
        awayMode = try c.decodeIfPresent(Bool.self, forKey: .awayMode) ?? awayMode
        quiet = try c.decodeIfPresent(Bool.self, forKey: .quiet) ?? quiet
        privacy = try c.decodeIfPresent(Bool.self, forKey: .privacy) ?? privacy
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? paused
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        summarizer = try c.decodeIfPresent(Bool.self, forKey: .summarizer) ?? summarizer
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        hideWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .hideWhenIdle) ?? hideWhenIdle
        hoverToOpen = try c.decodeIfPresent(Bool.self, forKey: .hoverToOpen) ?? hoverToOpen
    }
}
