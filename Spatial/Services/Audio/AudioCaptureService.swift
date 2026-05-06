import Foundation

protocol AudioCaptureService: AnyObject {
    var captureState: AudioCaptureState { get }
    var onStateChange: ((AudioCaptureState) -> Void)? { get set }
    func prepare(for target: AudioCaptureTarget)
    func start()
    func stop()
}

enum AudioCaptureTarget: Equatable {
    case application(bundleIdentifier: String, displayName: String)
    case systemMix
    case externalInput(name: String)
}

protocol AudioSourceResolving {
    func captureTarget(for source: AudioSourceOption) -> AudioCaptureTarget
}

struct DefaultAudioSourceResolver: AudioSourceResolving {
    func captureTarget(for source: AudioSourceOption) -> AudioCaptureTarget {
        switch source {
        case .spotify:
            return .application(bundleIdentifier: "com.spotify.client", displayName: "Spotify")
        case .appleMusic:
            return .application(bundleIdentifier: "com.apple.Music", displayName: "Apple Music")
        case .systemAudio:
            return .systemMix
        case .externalInput:
            return .externalInput(name: "External Input")
        }
    }
}

enum AudioCaptureState: Equatable {
    case idle
    case armed
    case capturing
    case failed(String)
}
