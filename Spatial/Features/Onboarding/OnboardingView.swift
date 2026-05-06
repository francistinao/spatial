import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: SpatialAppModel

    var body: some View {
        OnboardingCardView(
            state: model.state,
            primaryButtonTitle: primaryButtonTitle,
            primaryButtonDisabled: model.isInstallingDriver,
            detailText: detailText,
            statusText: model.isInstallingDriver ? nil : model.driverInstallationStatus,
            onPrimaryAction: primaryAction,
            onLearnMore: {}
        )
    }

    private var primaryButtonTitle: String {
        if model.canContinuePastDriverInstallation {
            return "Continue"
        }
        if model.isInstallingDriver {
            return "Installing Spatial Speaker..."
        }
        return "Install Spatial Speaker"
    }

    private var detailText: String {
        if model.canContinuePastDriverInstallation {
            if model.isDriverReady {
                return "Spatial Speaker is available, so Spatial can route system audio through the virtual device and monitor the processed result on your real output."
            }

            return "Spatial Speaker is installed, but macOS still does not see a usable virtual output device. This build cannot start live capture until the HAL driver publishes a real device."
        }

        if model.isDriverReady {
            return "Spatial Speaker is available, so Spatial can route system audio through the virtual device and monitor the processed result on your real output."
        }

        return "Spatial can install its bundled Spatial Speaker virtual device for you, then restart Core Audio automatically. Your audio stays on your Mac."
    }

    private func primaryAction() {
        if model.canContinuePastDriverInstallation {
            model.refreshPermissionState()
        } else {
            model.installBundledDriver()
        }
    }
}
