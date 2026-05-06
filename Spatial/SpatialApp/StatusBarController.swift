import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()
    private let settingsPopover = NSPopover()
    private var onboardingWindowController: OnboardingWindowController?
    private var sourceSelectionWindowController: SourceSelectionWindowController?
    private var widgetWindowController: WidgetWindowController?
    private var setupProgressTimer: Timer?
    private let environment: AppEnvironment
    private let appModel: SpatialAppModel

    init(environment: AppEnvironment) {
        self.environment = environment
        self.appModel = SpatialAppModel(environment: environment)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configurePopovers()
        configureMenu()
        configureStatusItem()
        configureOnboardingObservation()
        configureSetupProgressTimer()
        presentSetupFlowIfNeeded()
    }

    private func configurePopovers() {
        widgetWindowController = WidgetWindowController(
            model: appModel,
            openSettings: { [weak self] in self?.toggleSettingsPopover() }
        )

        settingsPopover.behavior = .transient
        settingsPopover.animates = true
        settingsPopover.contentSize = NSSize(
            width: SpatialMetrics.settingsPopoverWidth,
            height: SpatialMetrics.settingsPopoverHeight
        )
        settingsPopover.contentViewController = NSHostingController(
            rootView: SettingsView(model: appModel)
        )
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = statusImage
        button.imagePosition = .imageOnly
        button.appearsDisabled = false
        button.toolTip = "Spatial"
    }

    private func configureMenu() {
        statusMenu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    private var statusImage: NSImage? {
        let symbolName: String

        switch appModel.state.processingState {
        case .processing:
            symbolName = "waveform.path.ecg.rectangle.fill"
        case .idle:
            symbolName = appModel.state.isEnabled ? "dot.radiowaves.left.and.right" : "circle.dashed"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Spatial menu bar icon"
        )
        image?.isTemplate = false
        return image
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }

        appModel.refreshPermissionState()

        guard appModel.state.onboardingStatus == .completed else {
            presentSetupFlowIfNeeded()
            return
        }

        guard let widgetWindowController else { return }

        if widgetWindowController.window?.isVisible == true {
            widgetWindowController.close()
        } else {
            settingsPopover.performClose(sender)
            widgetWindowController.showWindow(sender)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc
    private func openSettingsFromMenu(_ sender: Any?) {
        widgetWindowController?.close()
        toggleSettingsPopover()
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func showStatusMenu() {
        guard let button = statusItem.button else { return }

        settingsPopover.performClose(button)
        widgetWindowController?.close()

        statusItem.menu = statusMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func toggleSettingsPopover() {
        guard let button = statusItem.button else { return }

        if settingsPopover.isShown {
            settingsPopover.performClose(button)
        } else {
            settingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func configureOnboardingObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func configureSetupProgressTimer() {
        setupProgressTimer = Timer.scheduledTimer(
            timeInterval: 0.75,
            target: self,
            selector: #selector(handleSetupProgressTimer),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func handleAppDidBecomeActive() {
        synchronizeSetupWindows()
    }

    @objc
    private func handleSetupProgressTimer() {
        synchronizeSetupWindows()
    }

    private func synchronizeSetupWindows() {
        appModel.refreshPermissionState()

        if appModel.state.onboardingStatus != .needsOnboarding {
            onboardingWindowController?.close()
            onboardingWindowController = nil
        }

        switch appModel.state.onboardingStatus {
        case .needsOnboarding:
            break
        case .needsSourceSelection:
            widgetWindowController?.close()
            presentSourceSelectionIfNeeded()
        case .completed:
            sourceSelectionWindowController?.close()
            sourceSelectionWindowController = nil
        }
    }

    private func presentSetupFlowIfNeeded() {
        appModel.refreshPermissionState()

        switch appModel.state.onboardingStatus {
        case .needsOnboarding:
            presentOnboardingIfNeeded()
        case .needsSourceSelection:
            presentSourceSelectionIfNeeded()
        case .completed:
            break
        }
    }

    private func presentOnboardingIfNeeded() {
        appModel.refreshPermissionState()
        guard appModel.state.onboardingStatus == .needsOnboarding else { return }

        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(model: appModel)
        }

        onboardingWindowController?.showWindow(nil)
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentSourceSelectionIfNeeded() {
        appModel.refreshPermissionState()
        guard appModel.state.onboardingStatus == .needsSourceSelection else { return }

        if sourceSelectionWindowController == nil {
            sourceSelectionWindowController = SourceSelectionWindowController(model: appModel)
        }

        sourceSelectionWindowController?.showWindow(nil)
    }
}
