import Foundation

protocol PresetStore {
    func loadPresets() -> [SpatialPreset]
}

struct InMemoryPresetStore: PresetStore {
    func loadPresets() -> [SpatialPreset] {
        SpatialPreset.all
    }
}
