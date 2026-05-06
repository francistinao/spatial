import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    init(model: SpatialAppModel) {
        let rootView = OnboardingView(model: model)
        let hostingController = NSHostingController(rootView: rootView)

        let window = SpatialOverlayPanel(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 420, height: 276))
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.center()
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true

        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
