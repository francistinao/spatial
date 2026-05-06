import Foundation

protocol SettingsStore {
    func load() -> SpatialSettings
    func save(_ settings: SpatialSettings)
}

final class InMemorySettingsStore: SettingsStore {
    private var cached = SpatialSettings.default

    func load() -> SpatialSettings {
        cached
    }

    func save(_ settings: SpatialSettings) {
        cached = settings
    }
}
