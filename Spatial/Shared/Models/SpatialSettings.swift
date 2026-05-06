import Foundation

enum SpatialTheme: String, Codable, CaseIterable, Identifiable {
    case violet
    case cyan
    case emerald
    case amber
    case rose
    case ice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .violet:
            return "Violet"
        case .cyan:
            return "Cyan"
        case .emerald:
            return "Emerald"
        case .amber:
            return "Amber"
        case .rose:
            return "Rose"
        case .ice:
            return "Ice"
        }
    }

    var accentHex: UInt32 {
        switch self {
        case .violet:
            return 0x7F5AF0
        case .cyan:
            return 0x22C7F5
        case .emerald:
            return 0x22C55E
        case .amber:
            return 0xF59E0B
        case .rose:
            return 0xF43F5E
        case .ice:
            return 0x60A5FA
        }
    }

    var accentLightHex: UInt32 {
        switch self {
        case .violet:
            return 0xA78BFA
        case .cyan:
            return 0x67E8F9
        case .emerald:
            return 0x86EFAC
        case .amber:
            return 0xFCD34D
        case .rose:
            return 0xFDA4AF
        case .ice:
            return 0xBFDBFE
        }
    }
}

struct SpatialSettings: Codable, Equatable {
    var rotation: Double
    var depth: Double
    var reverb: Double
    var width: Double
    var speed: Double
    var elevation: Double
    var theme: SpatialTheme = .violet

    static let `default` = SpatialPreset.classic.settings
}
