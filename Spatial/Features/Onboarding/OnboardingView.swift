import SwiftUI
import AppKit

struct OnboardingView: View {
    @ObservedObject var model: SpatialAppModel
    @State private var hasOpenedPermissionSettings = false

    var body: some View {
        OnboardingCardView(
            state: model.state,
            primaryButtonTitle: primaryButtonTitle,
            onPrimaryAction: primaryAction,
            onLearnMore: {}
        )
    }

    private var primaryButtonTitle: String {
        if model.state.screenRecordingAuthorized {
            return "Continue"
        }

        if hasOpenedPermissionSettings {
            return "I've Enabled Screen Recording"
        }

        return "Open System Settings"
    }

    private func primaryAction() {
        if model.state.screenRecordingAuthorized {
            model.completeScreenRecordingStep()
        } else if hasOpenedPermissionSettings {
            model.completeScreenRecordingStep()
        } else {
            hasOpenedPermissionSettings = true
            openPermissionSettings()
        }
    }

    private func openPermissionSettings() {
        model.requestScreenRecordingAuthorization()

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
