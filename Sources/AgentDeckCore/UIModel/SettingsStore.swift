import Foundation

public final class SettingsStore {
    public static let key = "AppSettings"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
    public func save(_ settings: AppSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
