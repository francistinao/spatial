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
    var centerFocus: Double
    var motionCurve: Double
    var theme: SpatialTheme = .violet
    var monitorOutputDeviceUID: String? = nil

    static let `default` = SpatialPreset.classic.settings

    init(
        rotation: Double,
        depth: Double,
        reverb: Double,
        width: Double,
        speed: Double,
        elevation: Double,
        centerFocus: Double = 0.60,
        motionCurve: Double = 0.35,
        theme: SpatialTheme = .violet,
        monitorOutputDeviceUID: String? = nil
    ) {
        self.rotation = rotation
        self.depth = depth
        self.reverb = reverb
        self.width = width
        self.speed = speed
        self.elevation = elevation
        self.centerFocus = centerFocus
        self.motionCurve = motionCurve
        self.theme = theme
        self.monitorOutputDeviceUID = monitorOutputDeviceUID
    }

    private enum CodingKeys: String, CodingKey {
        case rotation
        case depth
        case reverb
        case width
        case speed
        case elevation
        case centerFocus
        case motionCurve
        case theme
        case monitorOutputDeviceUID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try container.decode(Double.self, forKey: .rotation)
        depth = try container.decode(Double.self, forKey: .depth)
        reverb = try container.decode(Double.self, forKey: .reverb)
        width = try container.decode(Double.self, forKey: .width)
        speed = try container.decode(Double.self, forKey: .speed)
        elevation = try container.decode(Double.self, forKey: .elevation)
        centerFocus = try container.decodeIfPresent(Double.self, forKey: .centerFocus) ?? 0.60
        motionCurve = try container.decodeIfPresent(Double.self, forKey: .motionCurve) ?? 0.35
        theme = try container.decodeIfPresent(SpatialTheme.self, forKey: .theme) ?? .violet
        monitorOutputDeviceUID = try container.decodeIfPresent(String.self, forKey: .monitorOutputDeviceUID)
    }
}
