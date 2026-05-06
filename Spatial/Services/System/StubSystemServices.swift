import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

final class SystemAudioPermissionsService: PermissionsService {
    var isScreenRecordingAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingAuthorization() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}

final class StubPermissionsService: PermissionsService {
    var isScreenRecordingAuthorized: Bool {
        true
    }

    @discardableResult
    func requestScreenRecordingAuthorization() -> Bool {
        true
    }

    func openScreenRecordingSettings() {
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
