import SwiftUI

enum AudioSourceOption: String, CaseIterable, Identifiable {
    case spotify
    case appleMusic
    case systemAudio
    case externalInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotify:
            return "Spotify"
        case .appleMusic:
            return "Apple Music"
        case .systemAudio:
            return "System\nAudio"
        case .externalInput:
            return "External Input"
        }
    }

    var subtitle: String {
        switch self {
        case .spotify:
            return "Connected"
        case .appleMusic:
            return "Not Playing"
        case .systemAudio:
            return "Default Output"
        case .externalInput:
            return "Interface: XLR-1"
        }
    }

    var statusTint: Color {
        switch self {
        case .spotify:
            return Color(hex: 0x1DB954)
        case .appleMusic:
            return Color(hex: 0xD69A95)
        case .systemAudio:
            return SpatialColor.accent
        case .externalInput:
            return Color(hex: 0x53D8A8)
        }
    }

    var symbolName: String {
        switch self {
        case .spotify:
            return "music.note.list"
        case .appleMusic:
            return "music.note"
        case .systemAudio:
            return "desktopcomputer"
        case .externalInput:
            return "slider.horizontal.3"
        }
    }
}
