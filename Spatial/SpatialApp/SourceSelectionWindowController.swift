import AppKit
import Combine
import SwiftUI

final class SpatialOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SourceSelectionWindowController: NSWindowController {
    init(model: SpatialAppModel) {
        let hostingController = NSHostingController(
            rootView: SourceSelectionView(
                model: model,
                onConfigure: {},
                onInitialize: {
                    model.initializeSelectedSource()
                }
            )
        )

        let window = SpatialOverlayPanel(contentViewController: hostingController)
        window.setContentSize(
            NSSize(
                width: SpatialMetrics.sourceSelectionWidth,
                height: SpatialMetrics.sourceSelectionExpandedHeight
            )
        )
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.ignoresMouseEvents = false

        super.init(window: window)
        shouldCascadeWindows = false
        positionWindow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        positionWindow()
        window?.orderFrontRegardless()
    }

    private func positionWindow() {
        guard let window, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (window.frame.width / 2)
        let y = visibleFrame.maxY - window.frame.height + 10
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class WidgetWindowController: NSWindowController {
    private var cancellables = Set<AnyCancellable>()

    init(model: SpatialAppModel, openSettings: @escaping () -> Void) {
        let hostingController = NSHostingController(
            rootView: WidgetRootView(
                model: model,
                openSettings: openSettings
            )
        )

        let window = SpatialOverlayPanel(contentViewController: hostingController)
        window.setContentSize(Self.windowSize(for: model.widgetDisplayMode))
        window.styleMask = [.borderless]
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.ignoresMouseEvents = false

        super.init(window: window)
        shouldCascadeWindows = false
        positionWindow()

        model.$widgetDisplayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.window?.setContentSize(Self.windowSize(for: mode))
                self?.positionWindow()
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        positionWindow()
        window?.orderFrontRegardless()
    }

    private func positionWindow() {
        guard let window, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (window.frame.width / 2)
        let y = visibleFrame.maxY - window.frame.height + 10
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func windowSize(for mode: SpatialAppModel.WidgetDisplayMode) -> NSSize {
        switch mode {
        case .collapsed:
            return NSSize(width: SpatialMetrics.popoverWidth, height: SpatialMetrics.widgetCollapsedHeight)
        case .expanded:
            return NSSize(width: SpatialMetrics.popoverWidth, height: SpatialMetrics.widgetExpandedHeight)
        }
    }
}
