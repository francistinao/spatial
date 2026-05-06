import CoreAudio
import CoreGraphics
import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

final class StubAudioCaptureService: AudioCaptureService {
    private let logger = Logger(subsystem: "com.spatial.app", category: "AudioCapture")
    private(set) var captureState: AudioCaptureState = .idle {
        didSet {
            onStateChange?(captureState)
        }
    }
    private(set) var target: AudioCaptureTarget?
    var onStateChange: ((AudioCaptureState) -> Void)?

    func prepare(for target: AudioCaptureTarget) {
        self.target = target
        captureState = .armed
        logger.info("Prepared capture target: \(String(describing: target), privacy: .public)")
    }

    func start() {
        captureState = .capturing
        logger.info("Capture service started in stub mode")
    }

    func stop() {
        captureState = .idle
        logger.info("Capture service stopped")
    }
}

final class StubDSPEngine: InputReactiveDSPEngine {
    private let logger = Logger(subsystem: "com.spatial.app", category: "DSPEngine")
    private(set) var processingGraphDescription: String = "AVAudioEnvironmentNode -> LFO -> Reverb -> Stereo Width"
    private(set) var currentStatus: DSPEngineStatus = .idle {
        didSet {
            onStatusChange?(currentStatus)
        }
    }
    let supportsLiveInputProcessing = false
    var onStatusChange: ((DSPEngineStatus) -> Void)?
    var onVisualizerUpdate: (([CGFloat]) -> Void)?
    private var visualizerTimer: Timer?
    private var phase: Double = 0
    private var currentSettings = SpatialSettings.default
    private var currentSource: AudioSourceOption?
    private var isBypassed = false
    private var inputLevel: Float = 0.18

    func configure(with settings: SpatialSettings) {
        currentSettings = settings
        processingGraphDescription = "Configured mock graph (rotation \(settings.rotation), width \(settings.width))"
        logger.debug("Configured stub DSP. rotation=\(settings.rotation, format: .fixed(precision: 2)) depth=\(settings.depth, format: .fixed(precision: 2)) reverb=\(settings.reverb, format: .fixed(precision: 2)) width=\(settings.width, format: .fixed(precision: 2)) speed=\(settings.speed, format: .fixed(precision: 2)) elevation=\(settings.elevation, format: .fixed(precision: 2))")
    }

    func start(for source: AudioSourceOption) {
        currentSource = source
        currentStatus = source == .spotify || source == .systemAudio
            ? (isBypassed ? .bypassed : .processing)
            : .waitingForSource(source.title.replacingOccurrences(of: "\n", with: " "))
        logger.info("Started stub DSP for source=\(source.rawValue, privacy: .public) status=\(String(describing: self.currentStatus), privacy: .public)")
        logger.warning("Live 8D processing is still stubbed. Visualizer and state are synthetic unless demo audio is active.")
        startVisualizer()
    }

    func stop() {
        visualizerTimer?.invalidate()
        visualizerTimer = nil
        currentSource = nil
        currentStatus = .idle
        logger.info("Stopped stub DSP")
        onVisualizerUpdate?(Array(repeating: 0.08, count: 28))
    }

    func setBypass(_ bypassed: Bool) {
        isBypassed = bypassed
        guard currentSource != nil else {
            currentStatus = .idle
            return
        }

        if case .waitingForSource = currentStatus {
            return
        }

        currentStatus = bypassed ? .bypassed : .processing
        logger.info("Set bypass to \(bypassed, privacy: .public)")
    }

    func update(settings: SpatialSettings) {
        configure(with: settings)
    }

    func updateInputLevel(_ level: Float) {
        inputLevel = max(0, min(1, level))
    }

    private func startVisualizer() {
        visualizerTimer?.invalidate()

        visualizerTimer = Timer.scheduledTimer(withTimeInterval: 1 / 24, repeats: true) { [weak self] _ in
            self?.emitVisualizerFrame()
        }
        visualizerTimer?.tolerance = 0.02
        emitVisualizerFrame()
    }

    private func emitVisualizerFrame() {
        phase += max(currentSettings.speed, 1) * 0.04

        let bars = (0..<28).map { index -> CGFloat in
            let normalizedIndex = Double(index) / 27.0
            let beat = Double(inputLevel)
            let orbitSpeed = max(currentSettings.speed, 1) * 0.22
            let widthBias = currentSettings.width * 0.18
            let depthBias = currentSettings.depth * 0.20
            let reverbSwell = currentSettings.reverb * 0.10
            let elevationSpread = currentSettings.elevation * 0.08
            let wave = sin((phase * orbitSpeed) + (normalizedIndex * (6.0 + (currentSettings.rotation * 3.5)))) * (0.10 + beat * 0.20)
            let pulse = cos((phase * 0.55) + (normalizedIndex * (10.0 + elevationSpread * 40.0))) * (0.05 + beat * 0.18)
            let beatLift = beat * (0.24 + depthBias)
            let floor = isBypassed ? 0.08 : 0.12
            let amplitude = floor + beatLift + wave + pulse + widthBias + reverbSwell
            return max(0.08, min(0.96, amplitude))
        }

        onVisualizerUpdate?(bars)
    }
}

final class SystemDemoPlaybackService: NSObject, DemoPlaybackService, AVAudioPlayerDelegate {
    private let logger = Logger(subsystem: "com.spatial.app", category: "DemoPlayback")
    private let demoURL = URL(fileURLWithPath: "/System/Library/Sounds/Hero.aiff")
    private var player: AVAudioPlayer?
    private var meterTimer: Timer?
    private(set) var isPlaying = false {
        didSet {
            guard oldValue != isPlaying else { return }
            onPlaybackChange?(isPlaying)
        }
    }

    var onPlaybackChange: ((Bool) -> Void)?
    var onLevelUpdate: ((Float) -> Void)?

    func startLoopingDemo() {
        guard !isPlaying else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: demoURL)
            player.delegate = self
            player.numberOfLoops = -1
            player.volume = 0.65
            player.isMeteringEnabled = true
            player.prepareToPlay()
            player.play()
            self.player = player
            isPlaying = true
            logger.info("Started looping demo audio at path: \(self.demoURL.path, privacy: .public)")
            startMetering()
        } catch {
            isPlaying = false
            logger.error("Failed to start demo audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stopDemo() {
        guard isPlaying || player != nil || meterTimer != nil else { return }

        meterTimer?.invalidate()
        meterTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        logger.info("Stopped demo audio")
        onLevelUpdate?(0)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        stopDemo()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1 / 24, repeats: true) { [weak self] _ in
            self?.emitMeterLevel()
        }
        meterTimer?.tolerance = 0.02
        emitMeterLevel()
    }

    private func emitMeterLevel() {
        guard let player, player.isPlaying else {
            onLevelUpdate?(0)
            return
        }

        player.updateMeters()
        let power = player.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (power + 50) / 50))
        onLevelUpdate?(normalized)
    }
}

final class LiveAudioPipelineBridge {
    private let lock = NSLock()
    private var sampleBufferHandler: ((CMSampleBuffer) -> Void)?
    private var captureStartedHandler: (() -> Void)?
    private var captureErrorHandler: ((String) -> Void)?

    func setSampleBufferHandler(_ handler: ((CMSampleBuffer) -> Void)?) {
        lock.lock()
        sampleBufferHandler = handler
        lock.unlock()
    }

    func setCaptureStartedHandler(_ handler: (() -> Void)?) {
        lock.lock()
        captureStartedHandler = handler
        lock.unlock()
    }

    func setCaptureErrorHandler(_ handler: ((String) -> Void)?) {
        lock.lock()
        captureErrorHandler = handler
        lock.unlock()
    }

    func deliver(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let handler = sampleBufferHandler
        lock.unlock()
        handler?(sampleBuffer)
    }

    func notifyCaptureStarted() {
        lock.lock()
        let handler = captureStartedHandler
        lock.unlock()
        handler?()
    }

    func notifyCaptureError(_ message: String) {
        lock.lock()
        let handler = captureErrorHandler
        lock.unlock()
        handler?(message)
    }
}

final class LiveAudioCaptureService: NSObject, AudioCaptureService, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "com.spatial.app", category: "LiveAudioCapture")
    private let pipeline: LiveAudioPipelineBridge
    private let sampleQueue = DispatchQueue(label: "com.spatial.app.capture-samples", qos: .userInitiated)
    private var stream: SCStream?
    private var startToken = UUID()
    private var isStopping = false

    private(set) var captureState: AudioCaptureState = .idle {
        didSet {
            onStateChange?(captureState)
        }
    }
    private(set) var target: AudioCaptureTarget?
    var onStateChange: ((AudioCaptureState) -> Void)?

    init(pipeline: LiveAudioPipelineBridge) {
        self.pipeline = pipeline
    }

    func prepare(for target: AudioCaptureTarget) {
        self.target = target
        captureState = .armed
        logger.info("Prepared live capture target: \(String(describing: target), privacy: .public)")
    }

    func start() {
        guard let target else {
            captureState = .failed("No audio source selected")
            pipeline.notifyCaptureError("No audio source selected")
            return
        }

        let token = UUID()
        startToken = token
        logger.info("Requested live capture start for target: \(String(describing: target), privacy: .public)")

        Task {
            await startCapture(for: target, token: token)
        }
    }

    func stop() {
        let token = UUID()
        startToken = token
        logger.info("Requested live capture stop")

        Task {
            await stopCurrentStream(updatingState: true)
        }
    }

    private func startCapture(for target: AudioCaptureTarget, token: UUID) async {
        logger.debug("Beginning live capture setup for target: \(String(describing: target), privacy: .public)")
        await stopCurrentStream(updatingState: false)

        do {
            logger.debug("Loading shareable content for live capture")
            let shareableContent = try await loadShareableContent()
            guard token == startToken else { return }

            logger.debug("Creating ScreenCaptureKit content filter")
            let contentFilter = try makeContentFilter(for: target, shareableContent: shareableContent)
            let configuration = makeStreamConfiguration()
            let stream = SCStream(filter: contentFilter, configuration: configuration, delegate: self)

            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            } catch {
                throw NSError(domain: "Spatial.LiveAudioCapture", code: -1000, userInfo: [
                    NSLocalizedDescriptionKey: "Unable to attach stream outputs: \(error.localizedDescription)"
                ])
            }

            self.stream = stream
            logger.debug("Starting ScreenCaptureKit stream")
            try await startCapture(stream)
            guard token == startToken else { return }

            captureState = .capturing
            isStopping = false
            scKitCallbackCount = 0
            scKitAudioCount = 0
            logger.info("Live capture started for target: \(String(describing: target), privacy: .public)")
            pipeline.notifyCaptureStarted()
        } catch {
            guard token == startToken else { return }
            let message = userFacingCaptureError(error, target: target)
            captureState = .failed(message)
            logger.error("Live capture failed: \(message, privacy: .public)")
            pipeline.notifyCaptureError(message)
        }
    }

    private func stopCurrentStream(updatingState: Bool) async {
        guard let stream else {
            if updatingState {
                captureState = .idle
            }
            return
        }

        isStopping = true
        self.stream = nil
        if updatingState {
            captureState = .idle
        }

        await withCheckedContinuation { continuation in
            stream.stopCapture(completionHandler: { [weak self] error in
                if let error {
                    self?.logger.error("Failed stopping live capture: \(error.localizedDescription, privacy: .public)")
                } else {
                    self?.logger.info("Stopped live capture")
                }
                continuation.resume()
            })
        }
    }

    private func loadShareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.current
    }

    private func startCapture(_ stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture(completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func makeContentFilter(for target: AudioCaptureTarget, shareableContent: SCShareableContent) throws -> SCContentFilter {
        guard let display = shareableContent.displays.first else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -1002, userInfo: [
                NSLocalizedDescriptionKey: "No displays are available to capture"
            ])
        }

        switch target {
        case .systemMix:
            let currentBundleIdentifier = Bundle.main.bundleIdentifier
            let excludedApplications = shareableContent.applications.filter { application in
                application.bundleIdentifier == currentBundleIdentifier
            }
            return SCContentFilter(display: display, excludingApplications: excludedApplications, exceptingWindows: [])

        case .application(let bundleIdentifier, let displayName):
            guard let application = shareableContent.applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                throw NSError(domain: "Spatial.LiveAudioCapture", code: -1003, userInfo: [
                    NSLocalizedDescriptionKey: "Open \(displayName) before starting Spatial"
                ])
            }
            return SCContentFilter(display: display, including: [application], exceptingWindows: [])

        case .externalInput(let name):
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -1004, userInfo: [
                NSLocalizedDescriptionKey: "\(name) is not wired into the live capture engine yet"
            ])
        }
    }

    private func makeStreamConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        if #available(macOS 14.0, *) {
            configuration.captureResolution = .nominal
        }
        return configuration
    }

    private func userFacingCaptureError(_ error: Error, target: AudioCaptureTarget) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        logger.error("Raw capture error. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(description, privacy: .public)")

        if description.localizedCaseInsensitiveContains("declined")
            || description.localizedCaseInsensitiveContains("not authorized")
            || description.localizedCaseInsensitiveContains("permission") {
            return "Allow Screen Recording for Spatial in System Settings"
        }

        switch target {
        case .application(_, let displayName):
            return "Could not capture audio from \(displayName): \(description)"
        case .systemMix:
            return "Could not capture system audio: \(description)"
        case .externalInput(let name):
            return "\(name) is not wired into the live engine yet"
        }
    }

    private var scKitCallbackCount = 0
    private var scKitAudioCount = 0

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        scKitCallbackCount += 1

        // Log every 60 callbacks so we know the delegate is firing at all
        if scKitCallbackCount % 60 == 1 {
            let isReady = CMSampleBufferDataIsReady(sampleBuffer)
            logger.info("SCKit callback #\(self.scKitCallbackCount, privacy: .public) type=\(type == .audio ? "audio" : "screen", privacy: .public) dataReady=\(isReady, privacy: .public) audioDelivered=\(self.scKitAudioCount, privacy: .public)")
        }

        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else {
            return
        }

        scKitAudioCount += 1
        pipeline.deliver(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        let message = userFacingCaptureError(error, target: target ?? .systemMix)
        captureState = .failed(message)
        logger.error("Capture stream stopped with error: \(message, privacy: .public)")
        pipeline.notifyCaptureError(message)
    }
}

final class LiveDSPEngine: InputReactiveDSPEngine {
    private struct InputFormatSignature: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let interleaved: Bool
    }

    private let logger = Logger(subsystem: "com.spatial.app", category: "LiveDSPEngine")
    private let pipeline: LiveAudioPipelineBridge
    private let processingQueue = DispatchQueue(label: "com.spatial.app.live-dsp", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let motionMixer = AVAudioMixerNode()
    private let reverbNode = AVAudioUnitReverb()
    private let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    private(set) var processingGraphDescription: String = "ScreenCaptureKit -> AVAudioPlayerNode -> Motion Mixer -> Reverb -> Output"
    private(set) var currentStatus: DSPEngineStatus = .idle {
        didSet {
            onStatusChange?(currentStatus)
        }
    }
    let supportsLiveInputProcessing = true
    var onStatusChange: ((DSPEngineStatus) -> Void)?
    var onVisualizerUpdate: (([CGFloat]) -> Void)?

    private var motionTimer: DispatchSourceTimer?
    private var currentSettings = SpatialSettings.default
    private var currentSource: AudioSourceOption?
    private var isBypassed = false
    private var phase: Double = 0
    private var inputLevel: Float = 0
    private var scheduledBufferCount = 0
    private var converter: AVAudioConverter?
    private var inputFormatSignature: InputFormatSignature?
    private var isCaptureRunning = false
    private var hasLoggedFirstLiveBuffer = false
    private var lastLoggedMeterBucket: Int?
    private var pinnedOutputDeviceID: AudioDeviceID?
    private var engineConfigObserver: NSObjectProtocol?

    init(pipeline: LiveAudioPipelineBridge) {
        self.pipeline = pipeline
        configureEngineGraph()
        installPipelineHandlers()
        installEngineConfigurationObserver()
    }

    deinit {
        if let observer = engineConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(with settings: SpatialSettings) {
        currentSettings = settings
        processingGraphDescription = "Live graph (rotation \(settings.rotation), width \(settings.width), reverb \(settings.reverb))"
        logger.debug("Configured live DSP. rotation=\(settings.rotation, format: .fixed(precision: 2)) depth=\(settings.depth, format: .fixed(precision: 2)) reverb=\(settings.reverb, format: .fixed(precision: 2)) width=\(settings.width, format: .fixed(precision: 2)) speed=\(settings.speed, format: .fixed(precision: 2)) elevation=\(settings.elevation, format: .fixed(precision: 2))")

        processingQueue.async { [weak self] in
            self?.applyRealtimeSettings()
        }
    }

    func start(for source: AudioSourceOption) {
        guard source != .externalInput else {
            currentSource = source
            currentStatus = .waitingForSource("External Input")
            return
        }

        installPipelineHandlers()

        // Enqueue the currentSource assignment on processingQueue so it runs AFTER
        // any previously enqueued stop() block. stop() sets currentSource = nil on
        // processingQueue; if we set it here on the main thread it races with that
        // block and gets overwritten, causing consume() to see nil and drop all buffers.
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.currentSource = source

            do {
                try self.ensureEngineRunning()
                self.startMotionTimerIfNeeded()
                self.currentStatus = self.isBypassed ? .bypassed : .armed
                self.logger.info("Started live DSP for source=\(source.rawValue, privacy: .public)")
            } catch {
                self.currentStatus = .error("Could not start audio engine")
                self.logger.error("Failed to start live DSP: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }

            self.motionTimer?.cancel()
            self.motionTimer = nil
            self.scheduledBufferCount = 0
            self.converter = nil
            self.inputFormatSignature = nil
            self.pinnedOutputDeviceID = nil
            self.playerNode.stop()
            self.playerNode.reset()
            self.engine.stop()
            self.currentSource = nil
            self.currentStatus = .idle
            self.resetCaptureDrivenState()
            self.logger.info("Stopped live DSP")
            self.emitIdleVisualizerFrame()
        }
    }

    func setBypass(_ bypassed: Bool) {
        isBypassed = bypassed

        processingQueue.async { [weak self] in
            guard let self else { return }
            self.applyRealtimeSettings()

            guard self.currentSource != nil else {
                self.currentStatus = .idle
                return
            }

            self.currentStatus = self.isCaptureRunning
                ? (bypassed ? .bypassed : .processing)
                : .armed
        }
    }

    func update(settings: SpatialSettings) {
        configure(with: settings)
    }

    func updateInputLevel(_ level: Float) {
        inputLevel = max(0, min(1, level))
    }

    func pinOutputDevice(_ deviceID: AudioDeviceID) {
        // Synchronous so the caller can switch the system default immediately after,
        // knowing the engine is already pinned to real hardware before BlackHole takes over.
        processingQueue.sync { [weak self] in
            guard let self else { return }
            self.pinnedOutputDeviceID = deviceID
            self.applyOutputDevicePin(deviceID)
        }
    }

    func unpinOutputDevice() {
        processingQueue.sync { [weak self] in
            self?.pinnedOutputDeviceID = nil
        }
    }

    @discardableResult
    private func applyOutputDevicePin(_ deviceID: AudioDeviceID) -> Bool {
        guard let audioUnit = engine.outputNode.audioUnit else {
            logger.error("Cannot pin output device: output audio unit unavailable (engine.isRunning=\(self.engine.isRunning, privacy: .public))")
            return false
        }

        var mutableID = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        var actualID: AudioDeviceID = 0
        var actualSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualID, &actualSize)

        let matched = actualID == deviceID
        logger.info("Pin output device: target=\(deviceID) actual=\(actualID) setStatus=\(setStatus) pinned=\(matched, privacy: .public)")
        return matched
    }

    private func configureEngineGraph() {
        reverbNode.loadFactoryPreset(.mediumHall)

        engine.attach(playerNode)
        engine.attach(motionMixer)
        engine.attach(reverbNode)

        engine.connect(playerNode, to: motionMixer, format: processingFormat)
        engine.connect(motionMixer, to: reverbNode, format: processingFormat)
        engine.connect(reverbNode, to: engine.mainMixerNode, format: processingFormat)

        engine.mainMixerNode.outputVolume = 1
        applyRealtimeSettings()
    }

    private func installPipelineHandlers() {
        pipeline.setSampleBufferHandler { [weak self] sampleBuffer in
            self?.processingQueue.async {
                self?.consume(sampleBuffer: sampleBuffer)
            }
        }

        pipeline.setCaptureStartedHandler { [weak self] in
            self?.processingQueue.async {
                guard let self, self.currentSource != nil else { return }
                self.isCaptureRunning = true
                self.currentStatus = self.isBypassed ? .bypassed : .processing
            }
        }

        pipeline.setCaptureErrorHandler { [weak self] message in
            self?.processingQueue.async {
                self?.resetCaptureDrivenState()
                self?.emitIdleVisualizerFrame()
                self?.currentStatus = .error(message)
            }
        }
    }

    private func ensureEngineRunning() throws {
        if engine.isRunning {
            return
        }

        try engine.start()
        applyRealtimeSettings()

        // Re-apply the pin AFTER start. engine.start() initialises the AUHAL and may
        // reset its current device to the system default. Setting the property on the
        // running unit overrides that without stopping the engine again.
        if let deviceID = pinnedOutputDeviceID {
            let pinned = applyOutputDevicePin(deviceID)
            if !pinned {
                logger.warning("Post-start pin did not take effect for device ID=\(deviceID) — engine may output to system default")
            }
        }
    }

    private func installEngineConfigurationObserver() {
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.processingQueue.async {
                guard let self, self.currentSource != nil else { return }
                self.logger.info("AVAudioEngine reconfigured — restarting and re-pinning output device")
                do {
                    try self.ensureEngineRunning()
                    if self.isCaptureRunning, !self.playerNode.isPlaying {
                        self.playerNode.play()
                    }
                } catch {
                    self.logger.error("Failed to restart engine after reconfiguration: \(error.localizedDescription, privacy: .public)")
                    self.currentStatus = .error("Audio engine lost its output device")
                }
            }
        }
    }

    private func applyRealtimeSettings() {
        if isBypassed {
            motionMixer.pan = 0
            motionMixer.outputVolume = 1
            reverbNode.wetDryMix = 0
            return
        }

        let reverbMix = Float(min(96, 8 + (currentSettings.reverb * 72) + (currentSettings.elevation * 10)))
        let depthVolume = Float(0.88 + (currentSettings.depth * 0.12))
        reverbNode.wetDryMix = reverbMix
        motionMixer.outputVolume = depthVolume
    }

    private func startMotionTimerIfNeeded() {
        guard motionTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 24.0, leeway: .milliseconds(15))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isCaptureRunning else {
                self.emitIdleVisualizerFrame()
                return
            }

            self.updateMotion()
            self.emitVisualizerFrame()
        }
        motionTimer = timer
        timer.resume()
    }

    private func updateMotion() {
        guard !isBypassed else {
            motionMixer.pan = 0
            return
        }

        phase += max(currentSettings.speed, 0.2) * 0.045

        let panRange = min(1.0, 0.12 + (currentSettings.rotation * 0.58) + (currentSettings.width * 0.30))
        let pan = sin(phase) * panRange
        let pulse = cos(phase * 0.5 + currentSettings.elevation * .pi)
        let volumeMotion = 0.90 + (currentSettings.depth * 0.08) + (pulse * currentSettings.elevation * 0.04)

        motionMixer.pan = Float(max(-1, min(1, pan)))
        motionMixer.outputVolume = Float(max(0.5, min(1.2, volumeMotion)))
    }

    private func emitVisualizerFrame() {
        let bars = (0..<28).map { index -> CGFloat in
            let normalizedIndex = Double(index) / 27.0
            let beat = Double(inputLevel)
            let orbitSpeed = max(currentSettings.speed, 1) * 0.20
            let widthBias = currentSettings.width * 0.20
            let depthBias = currentSettings.depth * 0.24
            let reverbSwell = currentSettings.reverb * 0.08
            let elevationSpread = currentSettings.elevation * 0.10
            let wave = sin((phase * orbitSpeed) + (normalizedIndex * (5.0 + (currentSettings.rotation * 4.0)))) * (0.12 + beat * 0.18)
            let pulse = cos((phase * 0.7) + (normalizedIndex * (11.0 + elevationSpread * 35.0))) * (0.05 + beat * 0.15)
            let amplitude = 0.10 + (beat * (0.30 + depthBias)) + wave + pulse + widthBias + reverbSwell
            return max(0.08, min(0.98, amplitude))
        }

        onVisualizerUpdate?(bars)
    }

    private func emitIdleVisualizerFrame() {
        onVisualizerUpdate?(Array(repeating: 0.08, count: 28))
    }

    private func resetCaptureDrivenState() {
        isCaptureRunning = false
        inputLevel = 0
        scheduledBufferCount = 0
        hasLoggedFirstLiveBuffer = false
        lastLoggedMeterBucket = nil
        consumeCallCount = 0
    }

    private var consumeCallCount = 0

    private func consume(sampleBuffer: CMSampleBuffer) {
        consumeCallCount += 1
        if consumeCallCount == 1 {
            logger.info("First sample buffer reached DSP engine consume(). source=\(self.currentSource?.rawValue ?? "nil", privacy: .public) isCaptureRunning=\(self.isCaptureRunning, privacy: .public)")
        }
        guard currentSource != nil, isCaptureRunning else {
            if consumeCallCount <= 3 {
                logger.warning("consume() guard failed. source=\(self.currentSource?.rawValue ?? "nil", privacy: .public) isCaptureRunning=\(self.isCaptureRunning, privacy: .public)")
            }
            return
        }

        do {
            try ensureEngineRunning()

            if scheduledBufferCount > 24 {
                logger.debug("Dropping captured buffer to keep latency bounded")
                return
            }

            guard let playbackBuffer = try makePlaybackBuffer(from: sampleBuffer) else {
                return
            }

            if !hasLoggedFirstLiveBuffer {
                hasLoggedFirstLiveBuffer = true
                logger.debug("Received first live audio buffer for visualizer metering")
            }

            updateMeter(from: playbackBuffer)
            scheduledBufferCount += 1

            playerNode.scheduleBuffer(playbackBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                self?.processingQueue.async {
                    guard let self else { return }
                    self.scheduledBufferCount = max(0, self.scheduledBufferCount - 1)
                }
            }

            if !playerNode.isPlaying {
                playerNode.play()
            }
        } catch {
            currentStatus = .error("Audio processing failed")
            logger.error("Audio processing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makePlaybackBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let sourceFormat = makeFormat(from: sampleBuffer),
              let sourceBuffer = try makePCMBuffer(from: sampleBuffer, format: sourceFormat) else {
            return nil
        }

        let signature = InputFormatSignature(
            sampleRate: sourceFormat.sampleRate,
            channelCount: sourceFormat.channelCount,
            commonFormat: sourceFormat.commonFormat,
            interleaved: sourceFormat.isInterleaved
        )

        if signature != inputFormatSignature || converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: processingFormat)
            inputFormatSignature = signature
        }

        guard let converter else {
            return sourceBuffer
        }

        let ratio = processingFormat.sampleRate / sourceFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * ratio).rounded(.up) + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var error: NSError?
        var didProvideInput = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error, let error {
            throw error
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    private func makeFormat(from sampleBuffer: CMSampleBuffer) -> AVAudioFormat? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        var description = asbd.pointee
        return AVAudioFormat(streamDescription: &description)
    }

    private func makePCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        pcmBuffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Unable to copy audio data from capture buffer"
            ])
        }

        return pcmBuffer
    }

    private func updateMeter(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let framesToSample = Int(min(buffer.frameLength, 2048))
        guard framesToSample > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<framesToSample {
                let sample = samples[frame]
                sum += sample * sample
            }
        }

        let mean = sum / Float(framesToSample * max(channelCount, 1))
        let rms = sqrt(mean)
        inputLevel = max(0.02, min(1, rms * 4.5))
        let meterBucket = Int((inputLevel * 10).rounded())
        if meterBucket != lastLoggedMeterBucket {
            lastLoggedMeterBucket = meterBucket
            logger.debug("Updated live input meter level=\(self.inputLevel, format: .fixed(precision: 3))")
        }
    }
}
