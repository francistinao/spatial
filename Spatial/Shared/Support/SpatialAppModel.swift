import AppKit
import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class SpatialAppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.spatial.app", category: "SpatialAppModel")
    private static let allowUnsafeSystemAudioFallback = ProcessInfo.processInfo.environment["SPATIAL_ALLOW_SYSTEM_AUDIO_FALLBACK"] == "1"

    enum WidgetDisplayMode: Equatable {
        case expanded
        case collapsed
    }

    @Published var state: SpatialAppState
    @Published var settings: SpatialSettings
    @Published var presets: [SpatialPreset]
    @Published var selectedPreset: SpatialPresetKind
    @Published var nowPlaying: NowPlayingInfo
    @Published var launchAtLoginEnabled: Bool
    @Published var selectedAudioSource: AudioSourceOption?
    @Published var widgetDisplayMode: WidgetDisplayMode
    @Published var visualizerBars: [CGFloat]
    @Published var engineStatus: DSPEngineStatus
    @Published var isDemoModeActive: Bool
    @Published var demoTrackName: String
    @Published var demoSourceDescription: String
    @Published private(set) var hasInitializedSelectedSource: Bool
    @Published private(set) var hasCompletedScreenRecordingStep: Bool
    @Published private(set) var hasAttemptedSelectedSourceInitialization: Bool
    @Published private(set) var isWaitingForScreenRecordingAuthorization: Bool
    @Published private(set) var isWaitingForScreenCapturePermission: Bool
    @Published private(set) var isInstallingDriver: Bool
    @Published private(set) var driverInstallationStatus: String?

    let environment: AppEnvironment
    private var playbackRefreshTimer: Timer?
    private var isWidgetManuallyExpanded = false
    private var isAwaitingCaptureStart = false
    /// Physical output UID last used for automatic monitor routing (8D playback), for unplug fallback.
    private var lastAutomaticMonitorOutputUID: String?
    private var lastLoggedNowPlayingSnapshot: NowPlayingInfo?
    private var lastLoggedDemoPlaybackSignature: String?

    var isDriverReady: Bool {
        environment.virtualAudioRoutingService.virtualDeviceAvailable
    }

    var isDriverBundleInstalledOnly: Bool {
        environment.audioDeviceService.isSpatialDriverInstalled && !isDriverReady
    }

    var isDriverInstalled: Bool {
        isDriverReady || environment.audioDeviceService.isSpatialDriverInstalled
    }

    var canContinuePastDriverInstallation: Bool {
        isDriverInstalled
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.settings = environment.settingsStore.load()
        self.presets = environment.presetStore.loadPresets()
        self.selectedPreset = .classic
        self.nowPlaying = environment.playbackMetadataService.currentNowPlaying(for: nil)
        self.launchAtLoginEnabled = environment.launchAtLoginService.isEnabled
        self.selectedAudioSource = nil
        self.widgetDisplayMode = .expanded
        self.visualizerBars = Array(repeating: 0.08, count: 28)
        self.engineStatus = environment.dspEngine.currentStatus
        self.isDemoModeActive = false
        self.demoTrackName = "Hero"
        self.demoSourceDescription = "macOS Spatial Demo"
        self.hasInitializedSelectedSource = false
        self.hasCompletedScreenRecordingStep = environment.virtualAudioRoutingService.virtualDeviceAvailable
            || environment.permissionsService.isScreenRecordingAuthorized
        self.hasAttemptedSelectedSourceInitialization = false
        self.isWaitingForScreenRecordingAuthorization = false
        self.isWaitingForScreenCapturePermission = false
        self.isInstallingDriver = false
        self.driverInstallationStatus = nil
        self.state = SpatialAppState(
            isEnabled: true,
            processingState: .idle,
            onboardingStatus: .needsOnboarding,
            recommendedOutput: "Install Spatial Speaker to begin live routing",
            screenRecordingAuthorized: environment.permissionsService.isScreenRecordingAuthorized
        )

        SpatialColor.setTheme(settings.theme)
        bindEngine()
        bindCaptureService()
        installHardwareMonitorRouteObserver()
        bindDemoPlayback()
        environment.dspEngine.configure(with: settings)
        startPlaybackRefreshTimer()
        refreshNowPlaying()
        refreshPermissionState()
    }

    func togglePower() {
        let nextValue = !state.isEnabled
        environment.dspEngine.setBypass(!nextValue)
        state.isEnabled = nextValue
        if nextValue {
            synchronizeDemoPlayback()
        } else {
            environment.demoPlaybackService.stopDemo()
        }
        applyEngineStatus(environment.dspEngine.currentStatus)
        refreshWidgetDisplayMode()
    }

    func selectPreset(_ kind: SpatialPresetKind) {
        guard let preset = presets.first(where: { $0.kind == kind }) else { return }
        let currentTheme = settings.theme
        selectedPreset = kind
        settings = preset.settings
        settings.theme = currentTheme
        environment.settingsStore.save(settings)
        environment.dspEngine.update(settings: settings)
    }

    func refreshPermissionState() {
        let driverReady = isDriverReady
        let driverInstalled = isDriverInstalled
        let screenRecordingAuthorized = environment.permissionsService.isScreenRecordingAuthorized
        let onboardingStatus: SpatialAppState.OnboardingStatus

        if driverInstalled || screenRecordingAuthorized {
            hasCompletedScreenRecordingStep = true
        }

        if driverReady {
            isWaitingForScreenRecordingAuthorization = false
            if driverInstallationStatus == "Installing Spatial Speaker..." {
                driverInstallationStatus = "Spatial Speaker is installed and ready."
            }
        } else if isDriverBundleInstalledOnly,
                  driverInstallationStatus == "Installing Spatial Speaker..." {
            driverInstallationStatus = bundledDriverUnavailableMessage
        }

        if !driverInstalled && !hasCompletedScreenRecordingStep {
            onboardingStatus = .needsOnboarding
        } else if selectedAudioSource == nil || !hasAttemptedSelectedSourceInitialization {
            onboardingStatus = .needsSourceSelection
        } else {
            onboardingStatus = .completed
        }

        state.onboardingStatus = onboardingStatus
        state.screenRecordingAuthorized = screenRecordingAuthorized
        refreshWidgetDisplayMode()
    }

    func installBundledDriver() {
        guard !isInstallingDriver else { return }

        if isDriverInstalled {
            driverInstallationStatus = isDriverReady
                ? "Spatial Speaker is already installed."
                : bundledDriverUnavailableMessage
            refreshPermissionState()
            return
        }

        isInstallingDriver = true
        driverInstallationStatus = "Installing Spatial Speaker..."

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await self.environment.driverInstaller.installDriver()
                let driverBecameAvailable = await self.waitForDriverAvailability()
                self.driverInstallationStatus = driverBecameAvailable
                    ? "Spatial Speaker is installed and ready."
                    : bundledDriverUnavailableMessage
                if !driverBecameAvailable {
                    self.presentRestartRequiredAlert()
                }
            } catch {
                self.driverInstallationStatus = error.localizedDescription
            }

            self.isInstallingDriver = false
            self.refreshPermissionState()
        }
    }

    func selectAudioSource(_ source: AudioSourceOption) {
        selectedAudioSource = source
        hasInitializedSelectedSource = false
        hasAttemptedSelectedSourceInitialization = false
        isWaitingForScreenRecordingAuthorization = false
        isWaitingForScreenCapturePermission = false
        isAwaitingCaptureStart = false
        isWidgetManuallyExpanded = false
        logger.info("Selected audio source: \(source.rawValue, privacy: .public)")
        nowPlaying = environment.playbackMetadataService.currentNowPlaying(for: source)
        synchronizeCaptureSignalExpectation()
        deactivateVirtualRouting()
        environment.audioCaptureService.stop()
        environment.dspEngine.stop()
        environment.demoPlaybackService.stopDemo()
        engineStatus = .armed
        applyEngineStatus(.armed)
        refreshPermissionState()
    }

    func initializeSelectedSource() {
        guard let selectedAudioSource else { return }
        let target = environment.audioSourceResolver.captureTarget(for: selectedAudioSource)
        logger.info("Initializing source=\(selectedAudioSource.rawValue, privacy: .public) target=\(String(describing: target), privacy: .public)")

        hasInitializedSelectedSource = false
        hasAttemptedSelectedSourceInitialization = true
        isWaitingForScreenRecordingAuthorization = false
        isWaitingForScreenCapturePermission = false
        isAwaitingCaptureStart = false

        if case .virtualDevice = target, !isDriverReady {
            if let issue = environment.virtualAudioRoutingService.virtualDeviceIssue {
                logger.error("Virtual device unavailable during source initialization: \(issue, privacy: .public)")
            } else {
                logger.error("Virtual device unavailable during source initialization with no reported issue")
            }
            isWaitingForScreenRecordingAuthorization = true
            applyEngineStatus(.error(missingVirtualDeviceMessage))
            refreshPermissionState()
            return
        }

        environment.dspEngine.stop()
        environment.dspEngine.configure(with: settings)
        synchronizeCaptureSignalExpectation()

        switch target {
        case .externalInput:
            environment.dspEngine.start(for: selectedAudioSource)
            environment.audioCaptureService.stop()
            applyEngineStatus(environment.dspEngine.currentStatus)
            hasInitializedSelectedSource = true
        case .virtualDevice:
            guard activateVirtualRouting() else {
                let message = isDriverReady
                    ? "Spatial could not route macOS audio to Spatial Speaker"
                    : missingVirtualDeviceMessage
                applyEngineStatus(.error(message))
                refreshPermissionState()
                return
            }
            environment.dspEngine.start(for: selectedAudioSource)
            isAwaitingCaptureStart = true
            environment.audioCaptureService.prepare(for: target)
            environment.audioCaptureService.start()
            applyEngineStatus(environment.dspEngine.currentStatus)
        case .systemMix:
            guard isDriverReady || Self.allowUnsafeSystemAudioFallback else {
                applyEngineStatus(.error(systemAudioRequiresSpatialSpeakerMessage))
                refreshPermissionState()
                return
            }
            guard ensureSystemAudioCaptureAccess() else {
                refreshPermissionState()
                return
            }
            if isDriverReady && !activateVirtualRouting() {
                logger.warning("Proceeding with system-audio fallback because virtual routing activation failed")
            }
            environment.dspEngine.start(for: selectedAudioSource)
            isAwaitingCaptureStart = true
            environment.audioCaptureService.prepare(for: target)
            environment.audioCaptureService.start()
            applyEngineStatus(environment.dspEngine.currentStatus)
        case .application:
            applyEngineStatus(.error("This source must route through Spatial Speaker first"))
        }

        applyEngineStatus(environment.dspEngine.currentStatus)
        refreshPermissionState()
        refreshNowPlaying()
        synchronizeDemoPlayback()
    }

    func expandWidget() {
        isWidgetManuallyExpanded = true
        widgetDisplayMode = .expanded
    }

    func collapseWidgetIfPossible() {
        isWidgetManuallyExpanded = false
        guard canCollapseToNotch else { return }
        widgetDisplayMode = .collapsed
    }

    func updateRotation(_ value: Double) {
        updateSettings { $0.rotation = value }
    }

    func updateDepth(_ value: Double) {
        updateSettings { $0.depth = value }
    }

    func updateReverb(_ value: Double) {
        updateSettings { $0.reverb = value }
    }

    func updateWidth(_ value: Double) {
        updateSettings { $0.width = value }
    }

    func updateSpeed(_ value: Double) {
        updateSettings { $0.speed = value }
    }

    func updateElevation(_ value: Double) {
        updateSettings { $0.elevation = value }
    }

    func updateCenterFocus(_ value: Double) {
        updateSettings { $0.centerFocus = value }
    }

    func updateMotionCurve(_ value: Double) {
        updateSettings { $0.motionCurve = value }
    }

    func updateTheme(_ theme: SpatialTheme) {
        SpatialColor.setTheme(theme)
        updateSettings { $0.theme = theme }
    }

    func updateMonitorOutputDeviceUID(_ uid: String?) {
        updateSettings { $0.monitorOutputDeviceUID = uid }
        if uid != nil {
            lastAutomaticMonitorOutputUID = nil
        }

        guard selectedAudioSource == .systemAudio || selectedAudioSource == .spotify || selectedAudioSource == .appleMusic else {
            return
        }

        if environment.virtualAudioRoutingService.isActive {
            deactivateVirtualRouting()
            _ = activateVirtualRouting()
        } else if let uid,
                  let liveDSPEngine = environment.dspEngine as? LiveDSPEngine,
                  let device = environment.audioDeviceService.deviceWithUID(uid),
                  !device.isSpatialVirtualDevice {
            liveDSPEngine.pinOutputDevice(device.id)
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        environment.launchAtLoginService.setEnabled(enabled)
        launchAtLoginEnabled = environment.launchAtLoginService.isEnabled
    }

    var isSourceActive: Bool {
        guard environment.dspEngine.supportsLiveInputProcessing else {
            return false
        }

        return isLiveCaptureActive
            && nowPlaying.isPlaying
            && nowPlaying.source == selectedAudioSource
            && !isDemoModeActive
    }

    var availableMonitorOutputs: [AudioOutputDevice] {
        environment.audioDeviceService.allOutputDevices().filter { !$0.isSpatialVirtualDevice }
    }

    var selectedMonitorOutputTitle: String {
        if let uid = settings.monitorOutputDeviceUID,
           let device = environment.audioDeviceService.deviceWithUID(uid),
           !device.isSpatialVirtualDevice {
            return device.name
        }

        if let currentOutput = environment.audioDeviceService.systemOutputDevice(),
           !currentOutput.isSpatialVirtualDevice {
            return "Automatic (\(currentOutput.name))"
        }

        if let firstAvailable = availableMonitorOutputs.first {
            return "Automatic (\(firstAvailable.name))"
        }

        return "No hardware output found"
    }

    var isLiveCaptureActive: Bool {
        guard environment.dspEngine.supportsLiveInputProcessing else {
            return false
        }

        guard selectedAudioSource != nil,
              state.isEnabled,
              hasInitializedSelectedSource,
              !isWaitingForScreenRecordingAuthorization,
              !isWaitingForScreenCapturePermission,
              !isAwaitingCaptureStart else {
            return false
        }

        if case .error = engineStatus {
            return false
        }

        return true
    }

    var areLiveControlsEnabled: Bool {
        isLiveCaptureActive
    }

    var liveControlsStatusText: String {
        if let selectedAudioSource, !hasAttemptedSelectedSourceInitialization {
            return "Start Live Audio for \(selectedAudioSource.title.replacingOccurrences(of: "\n", with: " ")) to enable realtime 8D controls."
        }

        if isWaitingForScreenRecordingAuthorization {
            return missingVirtualDeviceMessage
        }

        if isWaitingForScreenCapturePermission {
            return screenCapturePermissionMessage
        }

        if isAwaitingCaptureStart {
            return "Connecting live capture. Controls will unlock once Spatial Speaker starts streaming."
        }

        if case .error(let message) = engineStatus {
            return message
        }

        if !state.isEnabled {
            return "Turn Spatial back on to adjust the live 8D effect."
        }

        if hasInitializedSelectedSource && !environment.dspEngine.supportsLiveInputProcessing {
            return "This source is connected in preview mode only."
        }

        if isLiveCaptureActive {
            return "Realtime 8D controls are active."
        }

        return "Live capture is not active yet."
    }

    var canCollapseToNotch: Bool {
        state.onboardingStatus == .completed
    }

    var selectedSourceTitle: String {
        selectedAudioSource?.title.replacingOccurrences(of: "\n", with: " ") ?? "No Source"
    }

    var collapsedTitle: String {
        if isDemoModeActive {
            return demoTrackName
        }

        return nowPlaying.trackName.isEmpty ? selectedSourceTitle : nowPlaying.trackName
    }

    var collapsedSubtitle: String {
        if isDemoModeActive {
            return "SPATIAL DEMO"
        }

        if case .error = engineStatus {
            return "CAPTURE ERROR"
        }

        if isWaitingForScreenRecordingAuthorization {
            return "INSTALL SPATIAL SPEAKER"
        }

        if isWaitingForScreenCapturePermission {
            return "ALLOW SCREEN RECORDING"
        }

        if isAwaitingCaptureStart {
            return "STARTING LIVE AUDIO"
        }

        if hasInitializedSelectedSource && !environment.dspEngine.supportsLiveInputProcessing {
            return "PREVIEW ONLY"
        }

        return state.isEnabled && hasInitializedSelectedSource ? "SPATIAL ACTIVE" : "READY"
    }

    var displayArtistName: String {
        if isDemoModeActive {
            return demoSourceDescription
        }

        return nowPlaying.artistName
    }

    var displayArtworkSystemName: String {
        if isDemoModeActive {
            return "music.note"
        }

        return nowPlaying.artworkSystemName ?? "waveform.circle.fill"
    }

    var displayArtworkURL: URL? {
        guard !isDemoModeActive else { return nil }
        return nowPlaying.artworkURL
    }

    var engineStatusText: String {
        if isWaitingForScreenRecordingAuthorization {
            return "Driver Required"
        }

        if isWaitingForScreenCapturePermission {
            return "Screen Recording Required"
        }

        if isAwaitingCaptureStart {
            return "Starting Live Capture"
        }

        if selectedAudioSource != nil && !hasAttemptedSelectedSourceInitialization {
            return "Source Selected"
        }

        if hasInitializedSelectedSource && !environment.dspEngine.supportsLiveInputProcessing {
            return "Preview Only"
        }

        switch engineStatus {
        case .idle:
            return "Engine Idle"
        case .armed:
            return "Engine Armed"
        case .processing:
            return "Processing Live"
        case .bypassed:
            return "Bypassed"
        case .waitingForSource(let source):
            return "Waiting for \(source)"
        case .error(let message):
            return message
        }
    }

    var sourceSelectionButtonTitle: String {
        if isWaitingForScreenRecordingAuthorization {
            return "Install Spatial Speaker"
        }

        if isWaitingForScreenCapturePermission {
            return "Open Screen Recording Settings"
        }

        if isAwaitingCaptureStart {
            return "Starting Live Audio"
        }

        if hasInitializedSelectedSource {
            return "Restart Live Audio"
        }

        return "Start Live Audio"
    }

    var isStartingSelectedSource: Bool {
        isAwaitingCaptureStart
    }

    var sourceSelectionBannerTitle: String {
        if hasInitializedSelectedSource {
            return "LIVE AUDIO ACTIVE"
        }

        if case .error = engineStatus {
            return "CAPTURE ERROR"
        }

        if isWaitingForScreenRecordingAuthorization {
            return "SPATIAL SPEAKER REQUIRED"
        }

        if isWaitingForScreenCapturePermission {
            return "SCREEN RECORDING REQUIRED"
        }

        if isAwaitingCaptureStart {
            return "CONNECTING LIVE SIGNAL"
        }

        return "AWAITING INPUT SIGNAL"
    }

    var sourceSelectionStatusText: String {
        guard let selectedAudioSource else {
            return "Choose a source to start live 8D processing."
        }

        let selectedSourceTitle = selectedAudioSource.title.replacingOccurrences(of: "\n", with: " ")

        if isWaitingForScreenRecordingAuthorization {
            return "\(missingVirtualDeviceMessage) \(selectedSourceTitle) will reconnect after the driver is available."
        }

        if isWaitingForScreenCapturePermission {
            return "\(screenCapturePermissionMessage) \(selectedSourceTitle) will reconnect after permission is granted."
        }

        if isAwaitingCaptureStart {
            return isDriverReady
                ? "Connecting \(selectedSourceTitle) to Spatial Speaker and the 8D engine."
                : "Connecting \(selectedSourceTitle) through the system-audio fallback and the 8D engine."
        }

        if case .error(let message) = engineStatus {
            return "\(message) Retry Start Live Audio after fixing the issue."
        }

        if hasInitializedSelectedSource {
            return "Live capture is active. Now playing metadata is separate from the loopback signal that drives the visualizer."
        }

        if isDriverReady {
            return "Selecting \(selectedSourceTitle) routes the target through Spatial Speaker so Spatial can capture the real signal for 8D motion and the visualizer."
        }

        return "Selecting \(selectedSourceTitle) captures the live system mix through ScreenCaptureKit so Spatial can drive the 8D engine and the visualizer."
    }

    var canStartSelectedSource: Bool {
        selectedAudioSource != nil && !isAwaitingCaptureStart
    }

    var spatialTuningSummary: String {
        "Orbit \(Int(settings.rotation * 100))  Space \(Int(settings.elevation * 100))  Focus \(Int(settings.centerFocus * 100))  Curve \(Int(settings.motionCurve * 100))"
    }

    var hasDryWetEchoRisk: Bool {
        environment.dspEngine.supportsLiveInputProcessing
            && isLiveCaptureActive
            && !isDemoModeActive
            && !environment.virtualAudioRoutingService.isActive
    }

    var echoRiskMessage: String {
        if environment.virtualAudioRoutingService.virtualDeviceAvailable {
            return "Hardware-only output may phase with the 8D signal. For the cleanest result, let Spatial route system audio through Spatial Speaker."
        }
        return "Install Spatial Speaker in /Library/Audio/Plug-Ins/HAL, then restart coreaudiod or reboot for clean echo-free routing."
    }

    deinit {
        playbackRefreshTimer?.invalidate()
    }

    private func bindEngine() {
        environment.dspEngine.onStatusChange = { [weak self] status in
            guard let self else { return }
            Task { @MainActor in
                self.applyEngineStatus(status)
            }
        }

        environment.dspEngine.onVisualizerUpdate = { [weak self] bars in
            guard let self else { return }
            Task { @MainActor in
                self.visualizerBars = bars
            }
        }
    }

    private func bindCaptureService() {
        environment.audioCaptureService.onStateChange = { [weak self] captureState in
            guard let self else { return }
            Task { @MainActor in
                self.handleCaptureStateChange(captureState)
            }
        }
    }

    private func bindDemoPlayback() {
        environment.demoPlaybackService.onPlaybackChange = { [weak self] isPlaying in
            guard let self else { return }
            Task { @MainActor in
                self.isDemoModeActive = isPlaying
                self.refreshWidgetDisplayMode()
            }
        }

        environment.demoPlaybackService.onLevelUpdate = { [weak self] level in
            guard let self else { return }
            Task { @MainActor in
                (self.environment.dspEngine as? InputReactiveDSPEngine)?.updateInputLevel(level)
            }
        }
    }

    private func handleCaptureStateChange(_ captureState: AudioCaptureState) {
        switch captureState {
        case .idle:
            isAwaitingCaptureStart = false
            if hasInitializedSelectedSource {
                hasInitializedSelectedSource = false
                deactivateVirtualRouting()
                refreshPermissionState()
                refreshWidgetDisplayMode()
                synchronizeDemoPlayback()
            }
        case .armed:
            hasInitializedSelectedSource = false
            refreshPermissionState()
        case .capturing:
            isAwaitingCaptureStart = false
            isWaitingForScreenRecordingAuthorization = false
            isWaitingForScreenCapturePermission = false
            hasInitializedSelectedSource = true
            applyEngineStatus(environment.dspEngine.currentStatus)
            refreshPermissionState()
            refreshWidgetDisplayMode()
            synchronizeDemoPlayback()
        case .failed(let message):
            logger.error("Capture failed before initialization completed: \(message, privacy: .public)")
            isAwaitingCaptureStart = false
            hasInitializedSelectedSource = false
            deactivateVirtualRouting()
            isWaitingForScreenRecordingAuthorization = !isDriverReady
                && (message.localizedCaseInsensitiveContains("not installed")
                    || message.localizedCaseInsensitiveContains("Spatial Speaker"))
            isWaitingForScreenCapturePermission = !environment.permissionsService.isScreenRecordingAuthorized
                && message.localizedCaseInsensitiveContains("screen")
            applyEngineStatus(.error(message))
            refreshPermissionState()
            refreshWidgetDisplayMode()
            synchronizeDemoPlayback()
        }
    }

    private func activateVirtualRouting() -> Bool {
        let routing = environment.virtualAudioRoutingService
        guard !routing.isActive else { return true }

        let liveDSPEngine = environment.dspEngine as? LiveDSPEngine
        let activated = routing.activate(preferredMonitorDeviceUID: settings.monitorOutputDeviceUID) { deviceID in
            liveDSPEngine?.pinOutputDevice(deviceID)
        }

        if activated {
            logger.info("Virtual routing activated — system audio routed through Spatial Speaker")
            environment.audioDeviceService.captureRoutingPhysicalOutputBaseline()
            syncLastAutomaticMonitorOutputUIDFromEngineIfNeeded()
        } else if routing.virtualDeviceAvailable {
            logger.warning("Spatial Speaker is installed but routing activation failed")
        } else {
            logger.info("Virtual routing skipped — Spatial Speaker not installed")
        }

        return activated
    }

    private func deactivateVirtualRouting() {
        guard environment.virtualAudioRoutingService.isActive else { return }
        environment.virtualAudioRoutingService.deactivate()
        lastAutomaticMonitorOutputUID = nil
        environment.audioDeviceService.clearRoutingPhysicalOutputBaseline()
        logger.info("Virtual routing deactivated — system output restored")
    }

    private func installHardwareMonitorRouteObserver() {
        environment.audioDeviceService.observeHardwareOutputRouteChanges { [weak self] in
            Task { @MainActor in
                self?.handleAutomaticHardwareMonitorRouteChange()
            }
        }
    }

    private func syncLastAutomaticMonitorOutputUIDFromEngineIfNeeded() {
        guard settings.monitorOutputDeviceUID == nil,
              let liveEngine = environment.dspEngine as? LiveDSPEngine,
              let deviceID = liveEngine.pinnedMonitorOutputDeviceID,
              let device = environment.audioDeviceService.outputDevice(forID: deviceID) else {
            return
        }
        lastAutomaticMonitorOutputUID = device.uid
    }

    private func handleAutomaticHardwareMonitorRouteChange() {
        guard environment.virtualAudioRoutingService.isActive,
              settings.monitorOutputDeviceUID == nil,
              let liveEngine = environment.dspEngine as? LiveDSPEngine else {
            return
        }

        let delta = environment.audioDeviceService.routingPhysicalOutputDeltaUpdatingBaseline()

        if let preferred = Self.preferredAddedMonitorOutput(from: delta.added) {
            liveEngine.pinOutputDevice(preferred.id)
            lastAutomaticMonitorOutputUID = preferred.uid
            logger.info("Automatic monitor repinned for new output: \(preferred.name, privacy: .public)")
            return
        }

        guard !delta.removedUIDs.isEmpty,
              let pinnedUID = lastAutomaticMonitorOutputUID,
              delta.removedUIDs.contains(pinnedUID) else {
            return
        }

        guard let fallback = Self.fallbackAutomaticMonitorOutput(
            excludingUIDs: delta.removedUIDs,
            deviceService: environment.audioDeviceService
        ) else {
            return
        }

        liveEngine.pinOutputDevice(fallback.id)
        lastAutomaticMonitorOutputUID = fallback.uid
        logger.info("Automatic monitor repinned after unplug: \(fallback.name, privacy: .public)")
    }

    private static func preferredAddedMonitorOutput(from added: [AudioOutputDevice]) -> AudioOutputDevice? {
        guard !added.isEmpty else { return nil }
        let annotated = added.map { ($0, $0.name.lowercased()) }
        if let match = annotated.first(where: {
            $0.1.contains("headphone") || $0.1.contains("headset") || $0.1.contains("earphone")
        }) {
            return match.0
        }
        if let match = annotated.first(where: { $0.1.contains("airpods") }) {
            return match.0
        }
        return added.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.first
    }

    private static func fallbackAutomaticMonitorOutput(
        excludingUIDs: Set<String>,
        deviceService: AudioDeviceService
    ) -> AudioOutputDevice? {
        let physical = deviceService.allOutputDevices().filter {
            $0.isSuitableHardwareMonitorOutputDevice && !excludingUIDs.contains($0.uid)
        }
        let annotated = physical.map { ($0, $0.name.lowercased()) }
        if let match = annotated.first(where: { $0.1.contains("macbook") && $0.1.contains("speaker") }) {
            return match.0
        }
        if let match = annotated.first(where: { $0.1.contains("built-in") && $0.1.contains("output") }) {
            return match.0
        }
        if let match = annotated.first(where: { $0.1.contains("speaker") }) {
            return match.0
        }
        return physical.first
    }

    private func startPlaybackRefreshTimer() {
        playbackRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNowPlaying()
            }
        }
        playbackRefreshTimer?.tolerance = 0.2
    }

    private func refreshNowPlaying() {
        let updatedNowPlaying = environment.playbackMetadataService.currentNowPlaying(for: selectedAudioSource)
        if updatedNowPlaying != nowPlaying {
            nowPlaying = updatedNowPlaying
        }
        synchronizeCaptureSignalExpectation()
        logNowPlayingRefreshIfNeeded()
        synchronizeDemoPlayback()
        refreshWidgetDisplayMode()
    }

    private func synchronizeCaptureSignalExpectation() {
        let expectedSignal = selectedAudioSource == nowPlaying.source && nowPlaying.isPlaying
        environment.audioCaptureService.setStartupSignalExpected(expectedSignal)
    }

    private var screenCapturePermissionMessage: String {
        "Allow Spatial in System Settings > Privacy & Security > Screen & System Audio Recording to use the system-audio fallback."
    }

    private var systemAudioRequiresSpatialSpeakerMessage: String {
        "\(missingVirtualDeviceMessage) System-audio fallback stays off by default because it can produce dangerously distorted output on some Macs."
    }

    private func ensureSystemAudioCaptureAccess() -> Bool {
        guard !isDriverReady else {
            return true
        }

        if environment.permissionsService.isScreenRecordingAuthorized {
            return true
        }

        let granted = environment.permissionsService.requestScreenRecordingAuthorization()
        refreshPermissionState()

        guard granted || environment.permissionsService.isScreenRecordingAuthorized else {
            isWaitingForScreenCapturePermission = true
            environment.permissionsService.openScreenRecordingSettings()
            applyEngineStatus(.error(screenCapturePermissionMessage))
            return false
        }

        isWaitingForScreenCapturePermission = false
        return true
    }

    private func refreshWidgetDisplayMode() {
        if isWidgetManuallyExpanded {
            widgetDisplayMode = .expanded
        } else {
            widgetDisplayMode = canCollapseToNotch ? .collapsed : .expanded
        }
    }

    private func applyEngineStatus(_ status: DSPEngineStatus) {
        engineStatus = status

        if isWaitingForScreenRecordingAuthorization {
            state.processingState = .idle
            state.recommendedOutput = missingVirtualDeviceMessage
            return
        }

        if isWaitingForScreenCapturePermission {
            state.processingState = .idle
            state.recommendedOutput = screenCapturePermissionMessage
            return
        }

        if selectedAudioSource != nil && !hasAttemptedSelectedSourceInitialization {
            state.processingState = .idle
            state.recommendedOutput = "Select Start Live Audio to begin capture"
            return
        }

        if isAwaitingCaptureStart {
            state.processingState = .idle
            state.recommendedOutput = "Connecting to Spatial Speaker"
            return
        }

        switch status {
        case .processing:
            if environment.dspEngine.supportsLiveInputProcessing {
                state.processingState = .processing
                state.recommendedOutput = hasDryWetEchoRisk
                    ? "Hardware-only mode may phase. Spatial Speaker gives the cleanest system-audio result."
                    : "Headphones Recommended"
            } else {
                state.processingState = .idle
                state.recommendedOutput = "Live 8D capture is not wired in this build"
            }
        case .bypassed:
            state.processingState = .idle
            state.recommendedOutput = "Spatial Bypassed"
        case .waitingForSource(let source):
            state.processingState = .idle
            state.recommendedOutput = "Waiting for \(source)"
        case .error(let message):
            state.processingState = .idle
            state.recommendedOutput = message
        case .armed:
            state.processingState = .idle
            state.recommendedOutput = "Engine Armed"
        case .idle:
            state.processingState = .idle
            state.recommendedOutput = "Headphones Recommended"
        }
    }

    private func updateSettings(_ mutate: (inout SpatialSettings) -> Void) {
        mutate(&settings)
        environment.settingsStore.save(settings)
        environment.dspEngine.update(settings: settings)
    }

    private func synchronizeDemoPlayback() {
        let shouldUseDemo = hasInitializedSelectedSource
            && !isAwaitingCaptureStart
            && state.isEnabled
            && !nowPlaying.isPlaying

        let logSignature = "\(shouldUseDemo)|\(hasInitializedSelectedSource)|\(state.isEnabled)|\(nowPlaying.isPlaying)"
        if logSignature != lastLoggedDemoPlaybackSignature {
            logger.debug("Synchronize demo playback. shouldUseDemo=\(shouldUseDemo, privacy: .public) initialized=\(self.hasInitializedSelectedSource, privacy: .public) enabled=\(self.state.isEnabled, privacy: .public) nowPlaying=\(self.nowPlaying.isPlaying, privacy: .public)")
            lastLoggedDemoPlaybackSignature = logSignature
        }

        if shouldUseDemo {
            guard !environment.demoPlaybackService.isPlaying else { return }
            environment.demoPlaybackService.startLoopingDemo()
        } else if environment.demoPlaybackService.isPlaying {
            environment.demoPlaybackService.stopDemo()
        }
    }

    private func logNowPlayingRefreshIfNeeded() {
        guard nowPlaying != lastLoggedNowPlayingSnapshot else { return }
        logger.debug("Now playing refresh. source=\(self.selectedAudioSource?.rawValue ?? "none", privacy: .public) title=\(self.nowPlaying.trackName, privacy: .public) artist=\(self.nowPlaying.artistName, privacy: .public) playing=\(self.nowPlaying.isPlaying, privacy: .public) demo=\(self.isDemoModeActive, privacy: .public)")
        lastLoggedNowPlayingSnapshot = nowPlaying
    }

    private var missingVirtualDeviceMessage: String {
        if let issue = environment.virtualAudioRoutingService.virtualDeviceIssue {
            return issue
        }

        if isDriverBundleInstalledOnly {
            return environment.audioDeviceService.missingSpatialVirtualDeviceIssue()
        }

        return "Install Spatial Speaker to let Spatial route and capture system audio."
    }

    private var bundledDriverUnavailableMessage: String {
        environment.audioDeviceService.missingSpatialVirtualDeviceIssue()
    }

    private func waitForDriverAvailability() async -> Bool {
        environment.audioDeviceService.invalidateSpatialVirtualDeviceReadinessCache()
        refreshPermissionState()
        if environment.virtualAudioRoutingService.virtualDeviceAvailable {
            return true
        }

        // Allow coreaudiod time to relaunch and enumerate the newly installed HAL bundle.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        for _ in 0..<30 {
            environment.audioDeviceService.invalidateSpatialVirtualDeviceReadinessCache()
            refreshPermissionState()
            if environment.virtualAudioRoutingService.virtualDeviceAvailable {
                return true
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return false
    }

    private func presentRestartRequiredAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Spatial Speaker Not Available"
        alert.informativeText = environment.audioDeviceService.missingSpatialVirtualDeviceIssue()
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Restart Anyway")

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }
        requestSystemRestart()
    }

    private func requestSystemRestart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "tell application \"System Events\" to restart"
        ]

        do {
            try process.run()
        } catch {
            logger.error("Failed to request system restart: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func checkProcessValidity<T>(_process: T) -> Bool {
        return _process is Process
    }
    
    private func repairSpatialAudioDevice() {
        guard #available(macOS 10.15, *) else { return }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            ""
        ];
    
        /**
         
         for argument in ["repair"] {
             process.arguments?.append("-e")
             process.arguments?.append("tell application \"System Preferences\" to reveal anchor \"Audio\" of pane \"Sound\"")
             
             argument.endIndex == argument.startIndex ? (
                 
             )
             : ()
         
         if checkProcessValidity(process) {
                 // repair HAL spatial speaker device
                 print("repair spatial audio device")
         }
         }
         */
        
        
    }
}
