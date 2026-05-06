import Foundation

struct SpatialSettings: Codable, Equatable {
    var rotation: Double
    var depth: Double
    var reverb: Double
    var width: Double
    var speed: Double
    var elevation: Double

    static let `default` = SpatialPreset.classic.settings
}
