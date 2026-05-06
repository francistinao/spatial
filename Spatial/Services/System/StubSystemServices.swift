import ApplicationServices
import CoreGraphics
import Foundation

final class SystemAudioPermissionsService: PermissionsService {
    var isScreenRecordingAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAuthorization() {
        _ = CGRequestScreenCaptureAccess()
    }
}

final class StubPermissionsService: PermissionsService {
    var isScreenRecordingAuthorized: Bool {
        true
    }

    func requestScreenRecordingAuthorization() {
    }
}

final class StubLaunchAtLoginService: LaunchAtLoginService {
    private(set) var isEnabled: Bool = false

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
}

struct StubOutputDeviceObserver: OutputDeviceObserving {
    let currentOutputName = "Default Output"
}
