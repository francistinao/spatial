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
        settings: SpatialSettings(rotation: 0.36, depth: 0.22, reverb: 0.12, width: 0.55, speed: 2.6, elevation: 0.36, centerFocus: 0.78, motionCurve: 0.16)
    )
    static let classic = SpatialPreset(
        kind: .classic,
        settings: SpatialSettings(rotation: 0.52, depth: 0.38, reverb: 0.20, width: 0.68, speed: 3.2, elevation: 0.46, centerFocus: 0.62, motionCurve: 0.28)
    )
    static let deep = SpatialPreset(
        kind: .deep,
        settings: SpatialSettings(rotation: 0.68, depth: 0.58, reverb: 0.42, width: 0.78, speed: 2.0, elevation: 0.58, centerFocus: 0.48, motionCurve: 0.52)
    )
    static let concert = SpatialPreset(
        kind: .concert,
        settings: SpatialSettings(rotation: 0.76, depth: 0.64, reverb: 0.48, width: 0.82, speed: 3.4, elevation: 0.62, centerFocus: 0.42, motionCurve: 0.62)
    )

    static let all = [subtle, classic, deep, concert]
}
