import CoreGraphics
import Foundation

enum DSPEngineStatus: Equatable {
    case idle
    case armed
    case processing
    case bypassed
    case waitingForSource(String)
    case error(String)
}

protocol DSPEngine: AnyObject {
    var processingGraphDescription: String { get }
    var currentStatus: DSPEngineStatus { get }
    var supportsLiveInputProcessing: Bool { get }
    var onStatusChange: ((DSPEngineStatus) -> Void)? { get set }
    var onVisualizerUpdate: (([CGFloat]) -> Void)? { get set }

    func configure(with settings: SpatialSettings)
    func start(for source: AudioSourceOption)
    func stop()
    func setBypass(_ bypassed: Bool)
    func update(settings: SpatialSettings)
}

protocol DemoPlaybackService: AnyObject {
    var isPlaying: Bool { get }
    var onPlaybackChange: ((Bool) -> Void)? { get set }
    var onLevelUpdate: ((Float) -> Void)? { get set }

    func startLoopingDemo()
    func stopDemo()
}

protocol InputReactiveDSPEngine: DSPEngine {
    func updateInputLevel(_ level: Float)
}
