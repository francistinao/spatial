import Foundation

struct SpatialAppState: Equatable {
    enum ProcessingState: Equatable {
        case idle
        case processing
    }

    enum OnboardingStatus: Equatable {
        case needsOnboarding
        case needsSourceSelection
        case completed
    }

    var isEnabled: Bool
    var processingState: ProcessingState
    var onboardingStatus: OnboardingStatus
    var recommendedOutput: String
    var screenRecordingAuthorized: Bool
}
