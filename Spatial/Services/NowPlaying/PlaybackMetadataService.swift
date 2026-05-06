import Foundation

protocol PlaybackMetadataService {
    func currentNowPlaying(for selectedSource: AudioSourceOption?) -> NowPlayingInfo
}
