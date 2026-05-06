import Foundation

struct NowPlayingInfo: Equatable {
    var trackName: String
    var artistName: String
    var sourceName: String
    var isPlaying: Bool
    var source: AudioSourceOption?
    var artworkSystemName: String?
}
