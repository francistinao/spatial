import AppKit
import Combine
import SwiftUI

final class SpatialOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SourceSelectionWindowController: NSWindowController {
    private let panelState = SourceSelectionPanelState()
    private var stateObserver: AnyCancellable?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(model: SpatialAppModel) {
        let hostingController = NSHostingController(
            rootView: SourceSelectionView(
                model: model,
                panelState: panelState,
                onConfigure: {},
                onInitialize: {
                    model.initializeSelectedSource()
                }
            )
        )

        let window = SpatialOverlayPanel(contentViewController: hostingController)
        window.setContentSize(Self.windowSize(for: panelState.isExpanded))
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
        bindPanelState()
        installOutsideClickDismissal()
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

    override func close() {
        panelState.setExpanded(false, animated: false)
        super.close()
    }

    deinit {
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }

        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
    }

    private func positionWindow() {
        guard let window, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - (window.frame.width / 2)
        let y = visibleFrame.maxY - window.frame.height + 10
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func bindPanelState() {
        stateObserver = panelState.$isExpanded
            .receive(on: RunLoop.main)
            .sink { [weak self] isExpanded in
                guard let self else { return }
                self.window?.setContentSize(Self.windowSize(for: isExpanded))
                self.positionWindow()
            }
    }

    private func installOutsideClickDismissal() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(at: event.locationInWindow, in: event.window, screenLocation: nil)
            return event
        }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(at: .zero, in: nil, screenLocation: event.locationInWindow)
        }
    }

    private func handleOutsideClick(at locationInWindow: NSPoint, in eventWindow: NSWindow?, screenLocation: NSPoint?) {
        guard panelState.isExpanded, let window, window.isVisible else { return }

        if eventWindow === window {
            let localPoint = window.contentView?.convert(locationInWindow, from: nil) ?? locationInWindow
            if window.contentView?.bounds.contains(localPoint) == true {
                return
            }
        }

        let location = screenLocation ?? eventWindow?.convertPoint(toScreen: locationInWindow)
        guard let location else { return }

        if !window.frame.contains(location) {
            panelState.setExpanded(false)
        }
    }

    private static func windowSize(for isExpanded: Bool) -> NSSize {
        NSSize(
            width: SpatialMetrics.sourceSelectionWidth,
            height: isExpanded ? SpatialMetrics.sourceSelectionExpandedHeight : SpatialMetrics.sourceSelectionCollapsedHeight
        )
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
        let layout = SpatialMetrics.widgetLayout(for: NSScreen.main?.visibleFrame.height ?? SpatialMetrics.widgetExpandedHeight)
        switch mode {
        case .collapsed:
            return NSSize(width: SpatialMetrics.popoverWidth, height: SpatialMetrics.widgetCollapsedHeight)
        case .expanded:
            return NSSize(width: layout.width, height: layout.expandedHeight)
        }
    }
}
