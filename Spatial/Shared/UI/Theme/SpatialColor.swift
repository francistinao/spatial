import SwiftUI

enum SpatialColor {
    private static var currentTheme: SpatialTheme = .violet

    static let background = Color(hex: 0x0D0D0D)
    static let card = Color(hex: 0x1A1A1A)
    static let border = Color.white.opacity(0.07)
    static var accent: Color { Color(hex: currentTheme.accentHex) }
    static var accentLight: Color { Color(hex: currentTheme.accentLightHex) }
    static let activeGreen = Color(hex: 0x2CB67D)
    static let textPrimary = Color(hex: 0xFFFFFE)
    static let textSecondary = Color(hex: 0x94A1B2)
    static let textTertiary = Color(hex: 0x72757E)

    static func setTheme(_ theme: SpatialTheme) {
        currentTheme = theme
    }
}

extension Color {
    init(hex: UInt32) {
        let red = Double((hex & 0xFF0000) >> 16) / 255.0
        let green = Double((hex & 0x00FF00) >> 8) / 255.0
        let blue = Double(hex & 0x0000FF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
