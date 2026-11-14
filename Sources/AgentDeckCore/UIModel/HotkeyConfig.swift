import Foundation

public enum HotkeyAction: String, Codable, CaseIterable { case toggleExpand, allowTop, denyTop, openTop, privacy }

public struct Hotkey: Codable, Equatable {
    // Carbon masks as literals: Core must not import Carbon.
    public static let control: UInt32 = 0x1000, option: UInt32 = 0x0800, command: UInt32 = 0x0100, shift: UInt32 = 0x0200
    public var keyCode: UInt32; public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    public var includesControl: Bool { modifiers & Self.control != 0 }
}

public enum HotkeyError: Error, Equatable { case missingControl, duplicate(of: HotkeyAction) }

public struct HotkeyConfig: Codable, Equatable {
    public var bindings: [String: Hotkey]       // keyed by HotkeyAction.rawValue

    private static let co = Hotkey.control | Hotkey.option
    public static let defaults = HotkeyConfig(bindings: [
        HotkeyAction.toggleExpand.rawValue: Hotkey(keyCode: 49, modifiers: co),
        HotkeyAction.allowTop.rawValue: Hotkey(keyCode: 16, modifiers: co),
        HotkeyAction.denyTop.rawValue: Hotkey(keyCode: 45, modifiers: co),
        HotkeyAction.openTop.rawValue: Hotkey(keyCode: 31, modifiers: co),
        HotkeyAction.privacy.rawValue: Hotkey(keyCode: 4, modifiers: co),
    ])

    public subscript(_ action: HotkeyAction) -> Hotkey { bindings[action.rawValue] ?? Self.defaults.bindings[action.rawValue]! }

    public func setting(_ action: HotkeyAction, to key: Hotkey) throws -> HotkeyConfig {
        guard key.includesControl else { throw HotkeyError.missingControl }
        if let other = HotkeyAction.allCases.first(where: { $0 != action && self[$0] == key }) { throw HotkeyError.duplicate(of: other) }
        var c = self; c.bindings[action.rawValue] = key
        return c
    }

    public static func carbonModifiers(control: Bool, option: Bool, command: Bool, shift: Bool) -> UInt32 {
        (control ? Hotkey.control : 0) | (option ? Hotkey.option : 0) | (command ? Hotkey.command : 0) | (shift ? Hotkey.shift : 0)
    }
}

public struct HotkeyStore {
    public static let key = "Hotkeys"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Corrupt -> defaults; an entry lacking Control or duplicating an earlier action's key -> that action's default.
    public func load() -> HotkeyConfig {
        guard let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(HotkeyConfig.self, from: data) else { return .defaults }
        var out = HotkeyConfig(bindings: [:])
        for a in HotkeyAction.allCases {
            let k = saved.bindings[a.rawValue]
            let taken = out.bindings.values.contains { $0 == k }
            out.bindings[a.rawValue] = k.flatMap { $0.includesControl && !taken ? $0 : nil } ?? HotkeyConfig.defaults[a]
        }
        // A fallback default can still collide with a kept custom key; then nothing custom is trustworthy.
        return Set(out.bindings.values.map { "\($0.keyCode):\($0.modifiers)" }).count == out.bindings.count ? out : .defaults
    }

    public func save(_ config: HotkeyConfig) {
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Self.key) }
    }
}
