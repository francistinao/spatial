import Foundation

enum SpatialPresetKind: String, Codable, CaseIterable, Identifiable {
    case subtle
    case classic
    case deep
    case concert

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }
}

struct SpatialPreset: Codable, Equatable, Identifiable {
    let kind: SpatialPresetKind
    let settings: SpatialSettings

    var id: SpatialPresetKind { kind }

    static let subtle = SpatialPreset(
        kind: .subtle,
        settings: SpatialSettings(rotation: 0.40, depth: 0.25, reverb: 0.15, width: 0.60, speed: 3, elevation: 0.40, centerFocus: 0.76, motionCurve: 0.18)
    )
    static let classic = SpatialPreset(
        kind: .classic,
        settings: SpatialSettings(rotation: 0.60, depth: 0.45, reverb: 0.30, width: 0.80, speed: 4, elevation: 0.55, centerFocus: 0.60, motionCurve: 0.35)
    )
    static let deep = SpatialPreset(
        kind: .deep,
        settings: SpatialSettings(rotation: 0.80, depth: 0.70, reverb: 0.60, width: 0.90, speed: 2, elevation: 0.70, centerFocus: 0.42, motionCurve: 0.68)
    )
    static let concert = SpatialPreset(
        kind: .concert,
        settings: SpatialSettings(rotation: 0.90, depth: 0.80, reverb: 0.75, width: 1.00, speed: 5, elevation: 0.85, centerFocus: 0.30, motionCurve: 0.86)
    )

    static let all = [subtle, classic, deep, concert]
}
