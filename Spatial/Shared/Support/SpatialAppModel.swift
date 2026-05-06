import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class SpatialAppModel: ObservableObject {
    private let logger = Logger(subsystem: "com.spatial.app", category: "SpatialAppModel")
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

    let environment: AppEnvironment
    private var playbackRefreshTimer: Timer?
    private var isWidgetManuallyExpanded = false
    private var isAwaitingCaptureStart = false
    private var pendingInitializationSource: AudioSourceOption?
    private var isRetryingPendingInitialization = false
    private var lastSpeculativeRetryDate: Date?

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
        self.hasCompletedScreenRecordingStep = false
        self.hasAttemptedSelectedSourceInitialization = false
        self.isWaitingForScreenRecordingAuthorization = false
        self.state = SpatialAppState(
            isEnabled: true,
            processingState: .idle,
            onboardingStatus: .needsOnboarding,
            recommendedOutput: "Headphones Recommended",
            screenRecordingAuthorized: environment.permissionsService.isScreenRecordingAuthorized
        )

        SpatialColor.setTheme(settings.theme)
        bindEngine()
        bindCaptureService()
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

    func requestScreenRecordingAuthorization() {
        environment.permissionsService.requestScreenRecordingAuthorization()
        refreshPermissionState()
    }

    func openScreenRecordingSettings() {
        environment.permissionsService.openScreenRecordingSettings()
    }

    func completeScreenRecordingStep() {
        hasCompletedScreenRecordingStep = true

        if !environment.permissionsService.isScreenRecordingAuthorized {
            environment.permissionsService.requestScreenRecordingAuthorization()
        }

        refreshPermissionState()
    }

    func refreshPermissionState() {
        let screenRecordingAuthorized = environment.permissionsService.isScreenRecordingAuthorized
        let onboardingStatus: SpatialAppState.OnboardingStatus

        if screenRecordingAuthorized {
            hasCompletedScreenRecordingStep = true
            isWaitingForScreenRecordingAuthorization = false
        }

        if !screenRecordingAuthorized && !hasCompletedScreenRecordingStep {
            onboardingStatus = .needsOnboarding
        } else if selectedAudioSource == nil || !hasAttemptedSelectedSourceInitialization {
            onboardingStatus = .needsSourceSelection
        } else {
            onboardingStatus = .completed
        }

        state.onboardingStatus = onboardingStatus
        state.screenRecordingAuthorized = screenRecordingAuthorized
        refreshWidgetDisplayMode()
        retryPendingInitializationIfNeeded(screenRecordingAuthorized: screenRecordingAuthorized)
    }

    func selectAudioSource(_ source: AudioSourceOption) {
        selectedAudioSource = source
        hasInitializedSelectedSource = false
        hasAttemptedSelectedSourceInitialization = false
        isWaitingForScreenRecordingAuthorization = false
        isAwaitingCaptureStart = false
        pendingInitializationSource = nil
        lastSpeculativeRetryDate = nil
        isWidgetManuallyExpanded = false
        logger.info("Selected audio source: \(source.rawValue, privacy: .public)")
        nowPlaying = environment.playbackMetadataService.currentNowPlaying(for: source)
        deactivateEchoPrevention()
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
        let screenRecordingAuthorized = environment.permissionsService.isScreenRecordingAuthorized
        logger.info("Initializing source=\(selectedAudioSource.rawValue, privacy: .public) target=\(String(describing: target), privacy: .public)")

        hasInitializedSelectedSource = false
        hasAttemptedSelectedSourceInitialization = true
        isWaitingForScreenRecordingAuthorization = false
        isAwaitingCaptureStart = false

        if targetRequiresScreenRecording(target),
           !screenRecordingAuthorized {
            logger.warning("Screen Recording permission was not pre-authorized at initialize time; requesting access and attempting live capture startup")
            environment.permissionsService.requestScreenRecordingAuthorization()
        }

        pendingInitializationSource = nil
        environment.dspEngine.stop()
        environment.dspEngine.configure(with: settings)
        environment.dspEngine.start(for: selectedAudioSource)

        switch target {
        case .externalInput:
            environment.audioCaptureService.stop()
            applyEngineStatus(environment.dspEngine.currentStatus)
            hasInitializedSelectedSource = true
        case .application, .systemMix:
            // Activate echo prevention BEFORE starting SCKit capture.
            // SCKit audio delivery is tied to the audio routing at stream-start time.
            // Switching the system output to BlackHole after the stream starts silently
            // kills audio delivery without any error. Starting with BlackHole already
            // set means SCKit captures the BlackHole-routed audio from the first buffer.
            activateEchoPrevention()
            isAwaitingCaptureStart = true
            environment.audioCaptureService.prepare(for: target)
            environment.audioCaptureService.start()
            applyEngineStatus(environment.dspEngine.currentStatus)
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

    func updateTheme(_ theme: SpatialTheme) {
        SpatialColor.setTheme(theme)
        updateSettings { $0.theme = theme }
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

    var isLiveCaptureActive: Bool {
        guard environment.dspEngine.supportsLiveInputProcessing else {
            return false
        }

        guard selectedAudioSource != nil,
              state.isEnabled,
              hasInitializedSelectedSource,
              !isWaitingForScreenRecordingAuthorization,
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
        if let selectedAudioSource,
           !hasAttemptedSelectedSourceInitialization {
            return "Start Live Audio for \(selectedAudioSource.title.replacingOccurrences(of: "\n", with: " ")) to enable realtime 8D controls."
        }

        if isWaitingForScreenRecordingAuthorization {
            return "Screen Recording is required before realtime 8D controls can affect live audio."
        }

        if isAwaitingCaptureStart {
            return "Connecting live capture. Controls will unlock once audio starts streaming."
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
        state.onboardingStatus == .completed && isSourceActive
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

    var engineStatusText: String {
        if isWaitingForScreenRecordingAuthorization {
            return "Permission Required"
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
            return "Waiting for Screen Recording"
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
            return "Grant Screen Recording in System Settings, then return to Spatial. \(selectedSourceTitle) will reconnect automatically."
        }

        if isAwaitingCaptureStart {
            return "Connecting to live audio from \(selectedSourceTitle)."
        }

        if case .error(let message) = engineStatus {
            return "\(message) Retry Start Live Audio after fixing the issue."
        }

        if hasInitializedSelectedSource {
            return "Live capture is active. Spotify now playing metadata is separate from the audio signal that drives the visualizer."
        }

        return "Selecting \(selectedSourceTitle) chooses the target. Start Live Audio to capture the real signal for 8D motion and the visualizer."
    }

    var canStartSelectedSource: Bool {
        selectedAudioSource != nil && !isWaitingForScreenRecordingAuthorization && !isAwaitingCaptureStart
    }

    var spatialTuningSummary: String {
        "Orbit \(Int(settings.rotation * 100))  Depth \(Int(settings.depth * 100))  Space \(Int(settings.elevation * 100))"
    }

    var hasDryWetEchoRisk: Bool {
        environment.dspEngine.supportsLiveInputProcessing
            && isLiveCaptureActive
            && !isDemoModeActive
            && !environment.echoPreventionService.isActive
    }

    var echoRiskMessage: String {
        if environment.echoPreventionService.blackHoleAvailable {
            return "To avoid echo, install BlackHole and Spatial will route audio automatically."
        }
        return "Install BlackHole (free) so Spatial can route audio without echo. Visit existential.audio/blackhole"
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
                deactivateEchoPrevention()
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
            pendingInitializationSource = nil
            hasInitializedSelectedSource = true
            applyEngineStatus(environment.dspEngine.currentStatus)
            refreshPermissionState()
            refreshWidgetDisplayMode()
            synchronizeDemoPlayback()
        case .failed(let message):
            logger.error("Capture failed before initialization completed: \(message, privacy: .public)")
            isAwaitingCaptureStart = false
            hasInitializedSelectedSource = false
            deactivateEchoPrevention()
            isWaitingForScreenRecordingAuthorization = isScreenRecordingPermissionError(message)
            if isWaitingForScreenRecordingAuthorization {
                pendingInitializationSource = selectedAudioSource
            } else {
                pendingInitializationSource = nil
            }
            applyEngineStatus(.error(message))
            refreshPermissionState()
            refreshWidgetDisplayMode()
            synchronizeDemoPlayback()
        }
    }

    private func activateEchoPrevention() {
        let echoPrevention = environment.echoPreventionService
        guard !echoPrevention.isActive else { return }

        let liveDSPEngine = environment.dspEngine as? LiveDSPEngine
        let activated = echoPrevention.activate { deviceID in
            liveDSPEngine?.pinOutputDevice(deviceID)
        }

        if activated {
            logger.info("Echo prevention activated — system audio routed through BlackHole")
        } else if echoPrevention.blackHoleAvailable {
            logger.warning("Echo prevention failed to activate despite BlackHole being present")
        } else {
            logger.info("Echo prevention skipped — BlackHole not installed")
        }
    }

    private func deactivateEchoPrevention() {
        guard environment.echoPreventionService.isActive else { return }
        environment.echoPreventionService.deactivate()
        logger.info("Echo prevention deactivated — system output restored")
    }

    private func targetRequiresScreenRecording(_ target: AudioCaptureTarget) -> Bool {
        switch target {
        case .application, .systemMix:
            return true
        case .externalInput:
            return false
        }
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
        nowPlaying = environment.playbackMetadataService.currentNowPlaying(for: selectedAudioSource)
        logger.debug("Now playing refresh. source=\(self.selectedAudioSource?.rawValue ?? "none", privacy: .public) title=\(self.nowPlaying.trackName, privacy: .public) artist=\(self.nowPlaying.artistName, privacy: .public) playing=\(self.nowPlaying.isPlaying, privacy: .public) demo=\(self.isDemoModeActive, privacy: .public)")
        synchronizeDemoPlayback()
        refreshWidgetDisplayMode()
        if isWaitingForScreenRecordingAuthorization {
            logger.debug("Polling permission state from timer (waiting for screen recording)")
            refreshPermissionState()
        }
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
            state.recommendedOutput = "Allow Screen Recording, then return to Spatial"
            return
        }

        if selectedAudioSource != nil && !hasAttemptedSelectedSourceInitialization {
            state.processingState = .idle
            state.recommendedOutput = "Select Start Live Audio to begin capture"
            return
        }

        if isAwaitingCaptureStart {
            state.processingState = .idle
            state.recommendedOutput = "Connecting to live audio capture"
            return
        }

        switch status {
        case .processing:
            if environment.dspEngine.supportsLiveInputProcessing {
                state.processingState = .processing
                state.recommendedOutput = hasDryWetEchoRisk
                    ? "Echo prevention needs BlackHole or Loopback routing"
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

        logger.debug("Synchronize demo playback. shouldUseDemo=\(shouldUseDemo, privacy: .public) initialized=\(self.hasInitializedSelectedSource, privacy: .public) enabled=\(self.state.isEnabled, privacy: .public) nowPlaying=\(self.nowPlaying.isPlaying, privacy: .public)")

        if shouldUseDemo {
            guard !environment.demoPlaybackService.isPlaying else { return }
            environment.demoPlaybackService.startLoopingDemo()
        } else if environment.demoPlaybackService.isPlaying {
            environment.demoPlaybackService.stopDemo()
        }
    }

    private func retryPendingInitializationIfNeeded(screenRecordingAuthorized: Bool) {
        // CGPreflightScreenCaptureAccess() returns a stale cached false in-process after
        // the user grants permission at runtime. When we're already in the waiting state,
        // bypass the preflight and attempt speculatively — SCShareableContent.current is
        // the authoritative check and will succeed if permission was actually granted.
        let isSpeculativeBypass = isWaitingForScreenRecordingAuthorization && !screenRecordingAuthorized
        let canAttempt = screenRecordingAuthorized || isWaitingForScreenRecordingAuthorization

        guard canAttempt,
              let pendingInitializationSource,
              pendingInitializationSource == selectedAudioSource,
              !hasInitializedSelectedSource,
              !isAwaitingCaptureStart,
              !isRetryingPendingInitialization else {
            return
        }

        // Rate-limit speculative retries to avoid a tight retry loop while permission
        // is still denied. Each failure immediately triggers this path via
        // handleCaptureStateChange(.failed) → refreshPermissionState(), so without
        // throttling the retry fires again before SCShareableContent.current returns.
        if isSpeculativeBypass {
            let now = Date()
            if let last = lastSpeculativeRetryDate, now.timeIntervalSince(last) < 5 {
                logger.debug("Retry throttled: last speculative attempt was \(now.timeIntervalSince(last), format: .fixed(precision: 1), privacy: .public)s ago")
                return
            }
            lastSpeculativeRetryDate = now
        }

        logger.info("Retrying pending live capture for source=\(pendingInitializationSource.rawValue, privacy: .public) speculativeBypass=\(isSpeculativeBypass, privacy: .public)")
        isRetryingPendingInitialization = true
        defer { isRetryingPendingInitialization = false }
        initializeSelectedSource()
    }

    private var screenRecordingPermissionMessage: String {
        "Allow Screen Recording for Spatial in System Settings"
    }

    private func isScreenRecordingPermissionError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("screen recording")
    }
}
