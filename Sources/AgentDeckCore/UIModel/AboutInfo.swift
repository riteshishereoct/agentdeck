import Foundation

/// Menu-bar menu titles and their SF Symbols (one place, so a test can prove every item has an icon).
public enum MenuCatalog {
    public static let symbols: [(title: String, symbol: String)] = [
        ("Show", "eye"), ("Hide", "eye.slash"),
        ("Away mode", "figure.walk"), ("Quiet", "bell.slash"), ("Privacy", "lock.shield"),
        ("Pause AgentDeck", "pause.circle"), ("Settings…", "gearshape"), ("Setup & Help…", "questionmark.circle"),
        ("Install or repair hooks…", "wrench.and.screwdriver"), ("Reload capabilities", "arrow.clockwise"),
        ("About AgentDeck", "info.circle"), ("Quit", "power"),
    ]
    public static func symbol(for title: String) -> String? { symbols.first { $0.title == title }?.symbol }
}

/// Plain-text facts for the About window and the "Copy details" block. Pure: the view feeds values in.
public struct AboutInfo: Equatable, Sendable {
    public var version: String?, build: String?
    public var hooks: String
    public var socketPath: String
    public var home: String

    public init(info: [String: Any]?, hooks: String, socketPath: String, home: String) {
        version = info?["CFBundleShortVersionString"] as? String
        build = info?["CFBundleVersion"] as? String
        self.hooks = hooks; self.socketPath = socketPath; self.home = home
    }

    public static let requirements = "macOS 14+, Apple silicon"
    public static let signing = "Ad-hoc signed · not notarized"
    public static let license = "MIT"

    /// "Version 0.2.0 (build 3)"; a bare `swift run` has no bundle.
    public var versionLine: String {
        switch (version, build) {
        case let (v?, b?): return "Version \(v) (build \(b))"
        case let (v?, nil): return "Version \(v)"
        default: return "Development build (no bundle)"
        }
    }

    public var displaySocket: String { Self.abbreviate(socketPath, home: home) }

    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Hook health across sessions: no sessions means nothing to judge yet.
    public static func hooksSummary(sessions: Int, degraded: Int) -> String {
        if sessions == 0 { return "No active sessions" }
        return degraded == 0 ? "Healthy (\(sessions) session\(sessions == 1 ? "" : "s"))" : "\(degraded) of \(sessions) need attention"
    }

    public var details: String {
        ["AgentDeck", versionLine, "Hooks: \(hooks)", "Socket: \(displaySocket)",
         "Requirements: \(Self.requirements)", "Signing: \(Self.signing)", "License: \(Self.license)"].joined(separator: "\n")
    }
}
