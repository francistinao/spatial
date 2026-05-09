import CoreAudio
import CoreGraphics
import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import OSLog
import ScreenCaptureKit

// #region agent log
/// Tiny NDJSON debug-mode logger for the workspace's session log file.
/// Used during the "HAL callbacks fire but every peak is 0.0000" debug session
/// (debug session id c5768c). Inlined here rather than in a separate file so it
/// does not require Xcode project surgery; remove together with all other
/// `// #region agent log` blocks once verification is complete.
private enum SpatialDebugLog {
    private static let logPath = "/Users/garuda/dev/spatial/.cursor/debug-c5768c.log"
    private static let sessionId = "c5768c"
    private static let queue = DispatchQueue(label: "com.spatial.app.debug-log", qos: .utility)

    static func log(hypothesisId: String, location: String, message: String, data: [String: Any] = [:]) {
        let timestamp = Date().timeIntervalSince1970 * 1000
        var payload: [String: Any] = [
            "sessionId": sessionId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": timestamp,
        ]
        payload["id"] = "log_\(Int(timestamp))_\(UUID().uuidString.prefix(8))"

        queue.async {
            let directory = (logPath as NSString).deletingLastPathComponent
            guard FileManager.default.fileExists(atPath: directory) else { return }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
            var line = jsonData
            line.append(0x0A)

            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                    defer { try? handle.close() }
                    do {
                        try handle.seekToEnd()
                        try handle.write(contentsOf: line)
                    } catch {}
                }
            } else {
                try? line.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    static func authName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
// #endregion

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

    func setStartupSignalExpected(_ expected: Bool) {
        logger.debug("Stub capture startup signal expectation updated. expected=\(expected, privacy: .public)")
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
        processingGraphDescription = "Configured mock graph (rotation \(settings.rotation), width \(settings.width), focus \(settings.centerFocus), curve \(settings.motionCurve))"
        logger.debug("Configured stub DSP. rotation=\(settings.rotation, format: .fixed(precision: 2)) depth=\(settings.depth, format: .fixed(precision: 2)) reverb=\(settings.reverb, format: .fixed(precision: 2)) width=\(settings.width, format: .fixed(precision: 2)) speed=\(settings.speed, format: .fixed(precision: 2)) elevation=\(settings.elevation, format: .fixed(precision: 2)) centerFocus=\(settings.centerFocus, format: .fixed(precision: 2)) motionCurve=\(settings.motionCurve, format: .fixed(precision: 2))")
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
            let focusTightness = 1 - (currentSettings.centerFocus * 0.48)
            let waveSeed = (phase * orbitSpeed) + (normalizedIndex * (6.0 + (currentSettings.rotation * 3.5)))
            let pulseSeed = (phase * (0.55 + (currentSettings.motionCurve * 0.18))) + (normalizedIndex * (10.0 + elevationSpread * 40.0))
            let wave = shapedMotionValue(for: waveSeed, curve: currentSettings.motionCurve) * (0.10 + beat * 0.20) * focusTightness
            let pulse = shapedMotionValue(for: pulseSeed, curve: currentSettings.motionCurve * 0.75) * (0.05 + beat * 0.18) * (0.88 - (currentSettings.centerFocus * 0.22))
            let beatLift = beat * (0.24 + depthBias)
            let floor = isBypassed ? 0.08 : 0.12
            let centerAnchor = currentSettings.centerFocus * 0.06
            let amplitude = floor + beatLift + wave + pulse + widthBias + reverbSwell + centerAnchor
            return max(0.08, min(0.96, amplitude))
        }

        onVisualizerUpdate?(bars)
    }

    private func shapedMotionValue(for phase: Double, curve: Double) -> Double {
        let base = sin(phase)
        let aggressive = base.sign == .minus
            ? -pow(abs(base), max(0.35, 1 - (curve * 0.55)))
            : pow(abs(base), max(0.35, 1 - (curve * 0.55)))
        return (base * (1 - curve)) + (aggressive * curve)
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
    private var pcmBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var captureStartedHandler: (() -> Void)?
    private var captureErrorHandler: ((String) -> Void)?

    func setPCMBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        pcmBufferHandler = handler
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

    func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = pcmBufferHandler
        lock.unlock()
        handler?(buffer)
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

private let liveCaptureInputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let service = Unmanaged<LiveAudioCaptureService>.fromOpaque(inRefCon).takeUnretainedValue()
    return service.handleHALInput(
        frameCount: inNumberFrames,
        ioActionFlags: ioActionFlags,
        timeStamp: inTimeStamp
    )
}

final class LiveAudioCaptureService: NSObject, AudioCaptureService {
    private struct LoopbackDecodedBuffer {
        let pcmBuffer: AVAudioPCMBuffer
        let frameCount: UInt32
        let peak: Float
        let layoutDescription: String
    }

    private struct CaptureStreamConfiguration {
        let streamID: AudioObjectID
        let deviceFormat: AVAudioFormat
        let processingFormat: AVAudioFormat
        let streamDescription: AudioStreamBasicDescription

        var isInterleaved: Bool { deviceFormat.isInterleaved }
        var channelCount: Int { Int(deviceFormat.channelCount) }
    }

    private enum LoopbackBackend: String {
        case deviceIOProc
        case halInputUnit
    }

    private enum CaptureAttemptProgress: String {
        case armed
        case startedInHAL
        case driverInputStarted
        case driverReadInputObserved
        case healthySignalConfirmed
    }

    private let logger = Logger(subsystem: "com.spatial.app", category: "LiveAudioCapture")
    private let captureStartTimeout: TimeInterval = 6
    private let pipeline: LiveAudioPipelineBridge
    private let deviceService: AudioDeviceService
    private let captureQueue = DispatchQueue(label: "com.spatial.app.device-capture", qos: .userInteractive)
    private var ioProcID: AudioDeviceIOProcID?
    private var halInputAudioUnit: AudioUnit?
    private var screenCaptureSession: SystemAudioScreenCaptureSession?
    private var activeDeviceID: AudioDeviceID?
    private var captureConfiguration: CaptureStreamConfiguration?
    private var startToken = UUID()
    private var loopbackCallbackCount: UInt64 = 0
    private var lastLoopbackPeakBucket: Int?
    private var activeLoopbackBackend: LoopbackBackend?
    private var pendingFallbackDeviceID: AudioDeviceID?
    private var pendingFallbackDeviceName: String?
    private var isLoopbackFallbackPending = false
    private var hasConfirmedHealthySignal = false
    private var startupSignalExpected = true
    private let preferredLoopbackBackend: LoopbackBackend = .halInputUnit
    private var captureAttemptSerial: UInt64 = 0
    private var activeCaptureAttemptSerial: UInt64 = 0
    private var captureAttemptProgress: CaptureAttemptProgress = .armed

    // 320 callbacks ≈ 3.4 s at 48 kHz / 512 frames. On this setup Spotify's first
    // non-zero WriteMix can land a little over 2.1 s after routing flips to
    // Spatial Speaker, so keep the IOProc path alive long enough to observe it.
    private let startupSilenceValidationCallbacks: UInt64 = 320
    private let startupSilenceThreshold: Float = 1e-5
    // Give the HAL fallback a comparable grace window so we do not fail a route
    // handoff while the source app is still reconnecting to the virtual device.
    private let startupFailureValidationCallbacks: UInt64 = 240

    private(set) var captureState: AudioCaptureState = .idle {
        didSet {
            onStateChange?(captureState)
        }
    }
    private(set) var target: AudioCaptureTarget?
    var onStateChange: ((AudioCaptureState) -> Void)?

    init(pipeline: LiveAudioPipelineBridge, deviceService: AudioDeviceService) {
        self.pipeline = pipeline
        self.deviceService = deviceService
    }

    func prepare(for target: AudioCaptureTarget) {
        self.target = target
        captureState = .armed
        captureAttemptProgress = .armed
        logger.info("Prepared live capture target: \(String(describing: target), privacy: .public)")
    }

    func setStartupSignalExpected(_ expected: Bool) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.startupSignalExpected != expected else { return }

            let previous = self.startupSignalExpected
            self.startupSignalExpected = expected
            self.logger.info("Updated live capture startup signal expectation. expected=\(expected, privacy: .public)")

            guard expected, !previous, !self.hasConfirmedHealthySignal else { return }
            self.loopbackCallbackCount = 0
            self.lastLoopbackPeakBucket = nil
            self.logger.info("Playback resumed while capture was armed — resetting startup silence validation window")
        }
    }

    func start() {
        guard let target else {
            captureState = .failed("No audio source selected")
            pipeline.notifyCaptureError("No audio source selected")
            return
        }

        captureAttemptSerial += 1
        activeCaptureAttemptSerial = captureAttemptSerial
        captureAttemptProgress = .armed
        let token = UUID()
        startToken = token
        logger.info("Requested live capture start for target: \(String(describing: target), privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) preferredBackend=\(self.preferredLoopbackBackend.rawValue, privacy: .public)")
        scheduleCaptureStartTimeout(for: target, token: token)

        captureQueue.async { [weak self] in
            self?.startCapture(for: target, token: token)
        }
    }

    func stop() {
        let token = UUID()
        startToken = token
        logger.info("Requested live capture stop")

        captureQueue.async { [weak self] in
            self?.stopCurrentCapture(updatingState: true)
        }
    }

    private func startCapture(for target: AudioCaptureTarget, token: UUID) {
        logger.debug("Beginning live capture setup for target: \(String(describing: target), privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public)")
        stopCurrentCapture(updatingState: false)

        do {
            try beginDeviceCapture(for: target)
            guard token == startToken else { return }
            logger.info("Live capture armed for target: \(String(describing: target), privacy: .public) — waiting for healthy signal. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) backend=\(self.activeLoopbackBackend?.rawValue ?? "none", privacy: .public)")
        } catch {
            guard token == startToken else { return }
            let message = userFacingCaptureError(error, target: target)
            captureState = .failed(message)
            logger.error("Live capture failed: \(message, privacy: .public)")
            pipeline.notifyCaptureError(message)
        }
    }

    private func scheduleCaptureStartTimeout(for target: AudioCaptureTarget, token: UUID) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + captureStartTimeout) { [weak self] in
            self?.handleCaptureStartTimeout(for: target, token: token)
        }
    }

    private func handleCaptureStartTimeout(for target: AudioCaptureTarget, token: UUID) {
        guard token == startToken, captureState == .armed else { return }

        guard startupSignalExpected else {
            logger.info("Capture start timeout deferred because playback is not expected yet for target: \(String(describing: target), privacy: .public)")
            scheduleCaptureStartTimeout(for: target, token: token)
            return
        }

        startToken = UUID()
        let message = stalledCaptureMessage(for: target)
        captureState = .failed(message)
        logger.error("Live capture timed out before stream started: \(message, privacy: .public)")
        pipeline.notifyCaptureError(message)
    }

    private func stopCurrentCapture(updatingState: Bool) {
        if let ioProcID, let activeDeviceID {
            AudioDeviceStop(activeDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(activeDeviceID, ioProcID)
            self.ioProcID = nil
            logger.info("Stopped device-backed live capture")
        }

        if let halInputAudioUnit {
            AudioOutputUnitStop(halInputAudioUnit)
            AudioUnitUninitialize(halInputAudioUnit)
            AudioComponentInstanceDispose(halInputAudioUnit)
            self.halInputAudioUnit = nil
            logger.info("Stopped HAL input-unit live capture")
        }

        if let screenCaptureSession {
            screenCaptureSession.stop()
            self.screenCaptureSession = nil
            logger.info("Stopped ScreenCaptureKit system audio capture")
        }

        self.activeLoopbackBackend = nil
        self.activeDeviceID = nil
        self.captureConfiguration = nil
        self.loopbackCallbackCount = 0
        self.lastLoopbackPeakBucket = nil
        self.pendingFallbackDeviceID = nil
        self.pendingFallbackDeviceName = nil
        self.isLoopbackFallbackPending = false
        self.hasConfirmedHealthySignal = false
        self.captureAttemptProgress = .armed

        if updatingState {
            captureState = .idle
        }
    }

    private func beginDeviceCapture(for target: AudioCaptureTarget) throws {
        switch target {
        case .virtualDevice(let uid, let name):
            guard let device = deviceService.deviceWithUID(uid) else {
                throw NSError(domain: "Spatial.LiveAudioCapture", code: -2001, userInfo: [
                    NSLocalizedDescriptionKey: "\(name) is not installed yet. Install the Spatial Speaker driver, restart Core Audio, then try again."
                ])
            }

            try startLoopbackCapture(on: device.id, name: name)
        case .externalInput(let name):
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2002, userInfo: [
                NSLocalizedDescriptionKey: "\(name) is not wired into the live engine yet"
            ])
        case .application(_, let displayName):
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2003, userInfo: [
                NSLocalizedDescriptionKey: "\(displayName) must be routed through Spatial Speaker before capture can start"
            ])
        case .systemMix:
            let readiness = deviceService.spatialVirtualDeviceReadiness()
            if let device = readiness.device, readiness.issue == nil {
                try startLoopbackCapture(on: device.id, name: AudioDeviceService.spatialVirtualDeviceName)
            } else {
                try startScreenCaptureSystemAudio()
            }
        }
    }

    private func startScreenCaptureSystemAudio() throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2008, userInfo: [
                NSLocalizedDescriptionKey: "System audio fallback requires macOS 13 or later."
            ])
        }

        let session = SystemAudioScreenCaptureSession(pipeline: pipeline, logger: logger)
        try session.start()
        screenCaptureSession = session
        logger.info("ScreenCaptureKit system audio capture armed")
    }

    private func startLoopbackCapture(on deviceID: AudioDeviceID, name: String) throws {
        logSpatialDeviceTopology(for: deviceID, name: name)
        switch preferredLoopbackBackend {
        case .halInputUnit:
            do {
                logger.info("Attempting primary loopback backend=\(LoopbackBackend.halInputUnit.rawValue, privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public) name=\(name, privacy: .public)")
                try startLoopbackCaptureWithHALInputUnit(on: deviceID, name: name)
            } catch {
                logger.error("HAL input-unit loopback capture setup failed; falling back to IOProc. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                try startLoopbackCaptureWithIOProc(on: deviceID, name: name)
            }
        case .deviceIOProc:
            do {
                logger.info("Attempting primary loopback backend=\(LoopbackBackend.deviceIOProc.rawValue, privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public) name=\(name, privacy: .public)")
                try startLoopbackCaptureWithIOProc(on: deviceID, name: name)
            } catch {
                logger.error("IOProc loopback capture setup failed; falling back to HAL input unit. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                try startLoopbackCaptureWithHALInputUnit(on: deviceID, name: name)
            }
        }
    }

    private func startLoopbackCaptureWithIOProc(on deviceID: AudioDeviceID, name: String) throws {
        let captureConfiguration = try makeCaptureStreamConfiguration(for: deviceID)
        let pipeline = self.pipeline
        let logger = self.logger

        var procID: AudioDeviceIOProcID?
        logger.info("Creating IOProc loopback capture. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public)")
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, captureQueue) {
            [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            let callbackCount = self.loopbackCallbackCount + 1
            self.loopbackCallbackCount = callbackCount
            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)

            let inputDecoded = self.decodeLoopbackBufferList(inputBuffers, format: captureConfiguration.processingFormat)
            let outputDecoded = self.decodeLoopbackBufferList(outputBuffers, format: captureConfiguration.processingFormat)

            if callbackCount <= 8 {
                let inputPeak = inputDecoded?.peak ?? -1
                let outputPeak = outputDecoded?.peak ?? -1
                logger.debug(
                    "DIAG IOProc callback n=\(callbackCount, privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) preferredBackend=\(self.preferredLoopbackBackend.rawValue, privacy: .public) expectedLoopbackSource=input input={\(self.audioBufferListSummary(inputBuffers), privacy: .public)} output={\(self.audioBufferListSummary(outputBuffers), privacy: .public)} inputPeak=\(inputPeak, format: .fixed(precision: 4)) outputPeak=\(outputPeak, format: .fixed(precision: 4))"
                )
            }

            let selectedBuffer: LoopbackDecodedBuffer?
            if let inputDecoded, let outputDecoded {
                selectedBuffer = outputDecoded.peak > inputDecoded.peak ? outputDecoded : inputDecoded
            } else {
                selectedBuffer = inputDecoded ?? outputDecoded
            }

            guard let selectedBuffer else {
                logger.error(
                    "Loopback callback could not decode either buffer list. input={\(self.audioBufferListSummary(inputBuffers), privacy: .public)} output={\(self.audioBufferListSummary(outputBuffers), privacy: .public)}"
                )
                UnsafeMutableAudioBufferListPointer(outOutputData).forEach { buf in
                    if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                }
                return
            }

            if callbackCount <= 8 {
                logger.debug(
                    "DIAG IOProc selected source n=\(callbackCount, privacy: .public) peak=\(selectedBuffer.peak, format: .fixed(precision: 4)) frames=\(selectedBuffer.frameCount, privacy: .public) layout=\(selectedBuffer.layoutDescription, privacy: .public)"
                )
            }

            // Zero-fill the output side after inspection so our capture client never
            // feeds synthetic audio back into the driver's write path.
            UnsafeMutableAudioBufferListPointer(outOutputData).forEach { buf in
                if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
            }

            self.processLoopbackBuffer(
                selectedBuffer.pcmBuffer,
                backend: .deviceIOProc,
                deviceID: deviceID,
                deviceName: name,
                callbackCount: callbackCount,
                bufferCount: max(inputBuffers.count, outputBuffers.count),
                frameCount: selectedBuffer.frameCount
            )
            pipeline.deliver(selectedBuffer.pcmBuffer)
        }

        guard createStatus == noErr, let procID else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2005, userInfo: [
                NSLocalizedDescriptionKey: "Could not create IO proc for Spatial Speaker (status=\(createStatus))"
            ])
        }

        logger.info("Created IOProc loopback capture. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public)")

        try configureIOProcStreamUsage(deviceID: deviceID, procID: procID)

        logger.info("Starting IOProc loopback capture. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public)")
        let startStatus = AudioDeviceStart(deviceID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, procID)
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2006, userInfo: [
                NSLocalizedDescriptionKey: "Could not start Spatial Speaker loopback capture (status=\(startStatus))"
            ])
        }

        self.ioProcID = procID
        self.activeDeviceID = deviceID
        self.captureConfiguration = captureConfiguration
        self.activeLoopbackBackend = .deviceIOProc
        self.pendingFallbackDeviceID = deviceID
        self.pendingFallbackDeviceName = name
        self.captureAttemptProgress = .driverInputStarted
        logger.info("Loopback capture armed on device '\(name, privacy: .public)' id=\(deviceID) backend=\(LoopbackBackend.deviceIOProc.rawValue, privacy: .public)")
    }

    private func startLoopbackCaptureWithHALInputUnit(on deviceID: AudioDeviceID, name: String) throws {
        // #region agent log
        // The Spatial Speaker driver advertises an input stream with terminal type
        // kAudioStreamTerminalTypeMicrophone. macOS TCC therefore gates capture behind
        // the kTCCServiceMicrophone permission. Without NSMicrophoneUsageDescription
        // declared in Info.plist, TCC silently denies (auth_value=0) and AUHAL DISABLES
        // the input stream — which is the exact symptom of "HAL callbacks fire but
        // every peak is 0.0000". See debug-c5768c.log for runtime evidence.
        let priorMicAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        SpatialDebugLog.log(hypothesisId: "H1", location: "StubAudioServices.swift:startLoopbackCaptureWithHALInputUnit", message: "before requestAccess(.audio)", data: ["priorAuth": priorMicAuth.rawValue, "priorAuthName": SpatialDebugLog.authName(priorMicAuth), "deviceID": Int(deviceID)])
        if priorMicAuth == .notDetermined {
            let semaphore = DispatchSemaphore(value: 0)
            var grantedFlag = false
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                grantedFlag = granted
                semaphore.signal()
            }
            semaphore.wait()
            SpatialDebugLog.log(hypothesisId: "H1", location: "StubAudioServices.swift:startLoopbackCaptureWithHALInputUnit", message: "requestAccess(.audio) returned", data: ["granted": grantedFlag])
        }
        let postMicAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        SpatialDebugLog.log(hypothesisId: "H1", location: "StubAudioServices.swift:startLoopbackCaptureWithHALInputUnit", message: "after requestAccess(.audio)", data: ["postAuth": postMicAuth.rawValue, "postAuthName": SpatialDebugLog.authName(postMicAuth), "deviceID": Int(deviceID)])
        if postMicAuth != .authorized {
            logger.error("Microphone permission is \(SpatialDebugLog.authName(postMicAuth), privacy: .public) — Spatial Speaker capture cannot read its loopback input. User must grant Microphone permission in System Settings > Privacy & Security > Microphone.")
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2014, userInfo: [
                NSLocalizedDescriptionKey: "Microphone permission is \(SpatialDebugLog.authName(postMicAuth)). Open System Settings > Privacy & Security > Microphone and grant access to Spatial, then try again."
            ])
        }
        // #endregion

        let captureConfiguration = try makeCaptureStreamConfiguration(for: deviceID)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2009, userInfo: [
                NSLocalizedDescriptionKey: "Core Audio HAL output unit is unavailable"
            ])
        }

        var audioUnit: AudioUnit?
        try checkStatus(
            AudioComponentInstanceNew(component, &audioUnit),
            message: "Could not create Spatial Speaker HAL input unit"
        )

        guard let audioUnit else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2010, userInfo: [
                NSLocalizedDescriptionKey: "Core Audio did not return a HAL input unit"
            ])
        }

        do {
            logger.info("Configuring HAL input-unit loopback capture. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public)")
            var enableInput: UInt32 = 1
            try setAUProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                scope: kAudioUnitScope_Input,
                element: 1,
                data: &enableInput,
                size: UInt32(MemoryLayout<UInt32>.size),
                label: "EnableIO/Input/elem1",
                message: "Could not enable Spatial Speaker input on HAL fallback unit"
            )

            var disableOutput: UInt32 = 0
            try setAUProperty(
                audioUnit,
                kAudioOutputUnitProperty_EnableIO,
                scope: kAudioUnitScope_Output,
                element: 0,
                data: &disableOutput,
                size: UInt32(MemoryLayout<UInt32>.size),
                label: "EnableIO/Output/elem0",
                message: "Could not disable Spatial Speaker output on HAL fallback unit"
            )

            var mutableDeviceID = deviceID
            try setAUProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                scope: kAudioUnitScope_Global,
                element: 0,
                data: &mutableDeviceID,
                size: UInt32(MemoryLayout<AudioDeviceID>.size),
                label: "CurrentDevice/Global/elem0",
                message: "Could not bind HAL fallback unit to Spatial Speaker"
            )

            // Log device-side hardware format on (Input, element=1) before we attempt to
            // override the AUHAL conversion-out format on (Output, element=1). Mismatch
            // between these two is the most common source of -10877.
            var hardwareFormat = AudioStreamBasicDescription()
            var hardwareFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let hardwareFormatStatus = AudioUnitGetProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                1,
                &hardwareFormat,
                &hardwareFormatSize
            )
            logger.info(
                "AU get StreamFormat/Input/elem1 attempt=\(self.activeCaptureAttemptSerial, privacy: .public) status=\(hardwareFormatStatus, privacy: .public) sampleRate=\(hardwareFormat.mSampleRate, privacy: .public) channels=\(hardwareFormat.mChannelsPerFrame, privacy: .public) bytesPerFrame=\(hardwareFormat.mBytesPerFrame, privacy: .public) flags=\(hardwareFormat.mFormatFlags, privacy: .public)"
            )

            var asbd = captureConfiguration.streamDescription
            logger.info(
                "AU set StreamFormat/Output/elem1 about-to-set sampleRate=\(asbd.mSampleRate, privacy: .public) channels=\(asbd.mChannelsPerFrame, privacy: .public) bytesPerFrame=\(asbd.mBytesPerFrame, privacy: .public) flags=\(asbd.mFormatFlags, privacy: .public)"
            )
            try setAUProperty(
                audioUnit,
                kAudioUnitProperty_StreamFormat,
                scope: kAudioUnitScope_Output,
                element: 1,
                data: &asbd,
                size: UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                label: "StreamFormat/Output/elem1",
                message: "Could not configure HAL fallback capture stream format"
            )

            var callback = AURenderCallbackStruct(
                inputProc: liveCaptureInputCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            try setAUProperty(
                audioUnit,
                kAudioOutputUnitProperty_SetInputCallback,
                scope: kAudioUnitScope_Global,
                element: 0,
                data: &callback,
                size: UInt32(MemoryLayout<AURenderCallbackStruct>.size),
                label: "SetInputCallback/Global/elem0",
                message: "Could not install HAL fallback capture callback"
            )

            logger.info("Initializing HAL input-unit loopback capture. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public)")
            let initializeStatus = AudioUnitInitialize(audioUnit)
            logger.info("AU AudioUnitInitialize attempt=\(self.activeCaptureAttemptSerial, privacy: .public) status=\(initializeStatus, privacy: .public)")
            try checkStatus(initializeStatus, message: "Could not initialize HAL fallback capture unit")
            logger.info("Starting HAL input-unit loopback capture. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public)")
            let startStatus = AudioOutputUnitStart(audioUnit)
            logger.info("AU AudioOutputUnitStart attempt=\(self.activeCaptureAttemptSerial, privacy: .public) status=\(startStatus, privacy: .public)")
            try checkStatus(startStatus, message: "Could not start HAL fallback capture unit")

            // Confirm coreaudiod considers the underlying device actually running. If
            // AudioOutputUnitStart returned noErr but kAudioDevicePropertyDeviceIsRunning
            // is still 0, that strongly indicates the device IO never started — which
            // matches the symptom of HAL callbacks delivering nothing but silence.
            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            var isRunningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let isRunningStatus = AudioObjectGetPropertyData(deviceID, &isRunningAddress, 0, nil, &isRunningSize, &isRunning)
            logger.info(
                "Spatial Speaker DeviceIsRunning post-start attempt=\(self.activeCaptureAttemptSerial, privacy: .public) deviceID=\(deviceID, privacy: .public) status=\(isRunningStatus, privacy: .public) isRunning=\(isRunning, privacy: .public)"
            )

            self.captureAttemptProgress = .startedInHAL
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }

        self.halInputAudioUnit = audioUnit
        self.activeDeviceID = deviceID
        self.captureConfiguration = captureConfiguration
        self.activeLoopbackBackend = .halInputUnit
        self.pendingFallbackDeviceID = deviceID
        self.pendingFallbackDeviceName = name
        self.loopbackCallbackCount = 0
        self.lastLoopbackPeakBucket = nil
        logger.info("Loopback capture armed on device '\(name, privacy: .public)' id=\(deviceID) backend=\(LoopbackBackend.halInputUnit.rawValue, privacy: .public)")
    }

    private func configureIOProcStreamUsage(deviceID: AudioDeviceID, procID: AudioDeviceIOProcID) throws {
        let inputStreams = try streamObjectIDs(for: deviceID, scope: kAudioObjectPropertyScopeInput)
        let outputStreams = try streamObjectIDs(for: deviceID, scope: kAudioObjectPropertyScopeOutput)
        let inputMask = String(repeating: "1", count: inputStreams.count)
        let outputMask = String(repeating: "1", count: outputStreams.count)

        guard !inputStreams.isEmpty, !outputStreams.isEmpty else {
            logger.error("Loopback stream usage resolution failed. inputStreams=\(inputStreams.count, privacy: .public) outputStreams=\(outputStreams.count, privacy: .public)")
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2011, userInfo: [
                NSLocalizedDescriptionKey: "Spatial Speaker stream topology is incomplete for IOProc capture"
            ])
        }

        try setIOProcStreamUsage(deviceID: deviceID, procID: procID, isInput: true, enabledStreamCount: inputStreams.count, streamMaskValue: 1)
        try setIOProcStreamUsage(deviceID: deviceID, procID: procID, isInput: false, enabledStreamCount: outputStreams.count, streamMaskValue: 1)

        logger.info(
            "Configured IOProc stream usage for Spatial Speaker. inputStreams=\(inputStreams.count, privacy: .public) outputStreams=\(outputStreams.count, privacy: .public) inputMask=\(inputMask, privacy: .public) outputMask=\(outputMask, privacy: .public)"
        )
    }

    private func setIOProcStreamUsage(deviceID: AudioDeviceID, procID: AudioDeviceIOProcID, isInput: Bool, enabledStreamCount: Int, streamMaskValue: UInt32) throws {
        let dataSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
            + max(enabledStreamCount - 1, 0) * MemoryLayout<UInt32>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: dataSize,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { rawPointer.deallocate() }

        let usage = rawPointer.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(enabledStreamCount)
        let streamMaskPointer = rawPointer
            .advanced(by: MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size)
            .assumingMemoryBound(to: UInt32.self)
        for index in 0..<enabledStreamCount {
            streamMaskPointer[index] = streamMaskValue
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: isInput ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(dataSize),
            rawPointer
        )
        try checkStatus(
            status,
            message: "Could not configure \(isInput ? "input" : "output") stream usage for Spatial Speaker IOProc"
        )
    }

    private func streamObjectIDs(for deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            message: "Could not query Spatial Speaker stream list"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var streamIDs = [AudioObjectID](repeating: 0, count: count)
        try checkStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &streamIDs),
            message: "Could not read Spatial Speaker stream list"
        )
        return streamIDs
    }

    private func describeStreamConfiguration(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope, scopeName: String) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            return "scope=\(scopeName) sizeStatus=\(sizeStatus) dataSize=\(dataSize)"
        }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }

        let dataStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawBuffer)
        guard dataStatus == noErr else {
            return "scope=\(scopeName) dataStatus=\(dataStatus)"
        }

        let bufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let pointer = UnsafeMutableAudioBufferListPointer(bufferList)
        let bufferDescriptions = pointer.enumerated().map { index, buffer in
            "buf\(index)={ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize)}"
        }.joined(separator: " ")
        let totalChannels = pointer.reduce(0) { $0 + Int($1.mNumberChannels) }
        return "scope=\(scopeName) buffers=\(pointer.count) totalChannels=\(totalChannels) \(bufferDescriptions)"
    }

    private func describeStream(streamID: AudioObjectID) -> String {
        var directionAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyDirection,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var direction: UInt32 = 0
        var directionSize = UInt32(MemoryLayout<UInt32>.size)
        let directionStatus = AudioObjectGetPropertyData(streamID, &directionAddress, 0, nil, &directionSize, &direction)

        var terminalAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyTerminalType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var terminal: UInt32 = 0
        var terminalSize = UInt32(MemoryLayout<UInt32>.size)
        let terminalStatus = AudioObjectGetPropertyData(streamID, &terminalAddress, 0, nil, &terminalSize, &terminal)

        var activeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyIsActive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isActive: UInt32 = 0
        var activeSize = UInt32(MemoryLayout<UInt32>.size)
        let activeStatus = AudioObjectGetPropertyData(streamID, &activeAddress, 0, nil, &activeSize, &isActive)

        let directionLabel: String
        switch direction {
        case 1: directionLabel = "input"
        case 0: directionLabel = "output"
        default: directionLabel = "unknown(\(direction))"
        }

        return "streamID=\(streamID) direction=\(directionLabel) terminal=0x\(String(terminal, radix: 16)) isActive=\(isActive) directionStatus=\(directionStatus) terminalStatus=\(terminalStatus) activeStatus=\(activeStatus)"
    }

    private func logSpatialDeviceTopology(for deviceID: AudioDeviceID, name: String) {
        let inputConfig = describeStreamConfiguration(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput, scopeName: "input")
        let outputConfig = describeStreamConfiguration(deviceID: deviceID, scope: kAudioObjectPropertyScopeOutput, scopeName: "output")
        let globalConfig = describeStreamConfiguration(deviceID: deviceID, scope: kAudioObjectPropertyScopeGlobal, scopeName: "global")

        let inputStreams = (try? streamObjectIDs(for: deviceID, scope: kAudioObjectPropertyScopeInput)) ?? []
        let outputStreams = (try? streamObjectIDs(for: deviceID, scope: kAudioObjectPropertyScopeOutput)) ?? []
        let globalStreams = (try? streamObjectIDs(for: deviceID, scope: kAudioObjectPropertyScopeGlobal)) ?? []

        let streamSummary = (inputStreams + outputStreams).map(describeStream(streamID:)).joined(separator: " | ")

        logger.info(
            "DIAG topology probe device='\(name, privacy: .public)' deviceID=\(deviceID, privacy: .public) inputStreams=\(inputStreams, privacy: .public) outputStreams=\(outputStreams, privacy: .public) globalStreams=\(globalStreams, privacy: .public)"
        )
        logger.info(
            "DIAG topology probe streamConfig device='\(name, privacy: .public)' \(inputConfig, privacy: .public) || \(outputConfig, privacy: .public) || \(globalConfig, privacy: .public)"
        )
        if !streamSummary.isEmpty {
            logger.info("DIAG topology probe streams device='\(name, privacy: .public)' \(streamSummary, privacy: .public)")
        }
    }

    fileprivate func handleHALInput(frameCount: UInt32, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>) -> OSStatus {
        guard let halInputAudioUnit, let captureConfiguration, let deviceID = activeDeviceID else {
            return noErr
        }

        let channelCount = captureConfiguration.channelCount
        let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
        let bufferCount = captureConfiguration.isInterleaved ? 1 : channelCount
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size
            + max(bufferCount - 1, 0) * MemoryLayout<AudioBuffer>.size
        let audioBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        ).bindMemory(to: AudioBufferList.self, capacity: 1)
        audioBufferList.pointee.mNumberBuffers = UInt32(bufferCount)
        let bufferListPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        for index in 0..<bufferCount {
            let numberChannels: UInt32 = captureConfiguration.isInterleaved ? UInt32(channelCount) : 1
            let byteSize = captureConfiguration.isInterleaved
                ? UInt32(Int(frameCount) * Int(captureConfiguration.streamDescription.mBytesPerFrame))
                : UInt32(bytesPerChannel)
            bufferListPointer[index] = AudioBuffer(
                mNumberChannels: numberChannels,
                mDataByteSize: byteSize,
                mData: UnsafeMutableRawPointer.allocate(byteCount: Int(byteSize), alignment: MemoryLayout<Float>.alignment)
            )
        }

        defer {
            for buffer in bufferListPointer where buffer.mData != nil {
                buffer.mData?.deallocate()
            }
            audioBufferList.deallocate()
        }

        let status = AudioUnitRender(halInputAudioUnit, ioActionFlags, timeStamp, 1, frameCount, audioBufferList)
        guard status == noErr else {
            logger.error("HAL fallback AudioUnitRender failed for Spatial Speaker capture. status=\(status)")
            return status
        }

        guard let decodedBuffer = decodeLoopbackBufferList(bufferListPointer, format: captureConfiguration.processingFormat) else {
            logger.error("HAL fallback AudioUnitRender returned an undecodable buffer layout. interleaved=\(captureConfiguration.isInterleaved, privacy: .public) buffers=\(bufferCount, privacy: .public) channels=\(channelCount, privacy: .public) frames=\(frameCount, privacy: .public)")
            return noErr
        }

        loopbackCallbackCount += 1
        if captureAttemptProgress == .startedInHAL {
            captureAttemptProgress = .driverInputStarted
        }
        if captureAttemptProgress == .driverInputStarted {
            captureAttemptProgress = .driverReadInputObserved
        }
        if loopbackCallbackCount <= 6 {
            logger.debug(
                "DIAG HAL callback n=\(self.loopbackCallbackCount, privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) preferredBackend=\(self.preferredLoopbackBackend.rawValue, privacy: .public) expectedLoopbackSource=input deviceInterleaved=\(captureConfiguration.isInterleaved, privacy: .public) buffers=\(bufferCount, privacy: .public) channels=\(channelCount, privacy: .public) frames=\(frameCount, privacy: .public)"
            )
        }
        processLoopbackBuffer(
            decodedBuffer.pcmBuffer,
            backend: .halInputUnit,
            deviceID: deviceID,
            deviceName: pendingFallbackDeviceName ?? AudioDeviceService.spatialVirtualDeviceName,
            callbackCount: loopbackCallbackCount,
            bufferCount: bufferCount,
            frameCount: decodedBuffer.frameCount
        )
        pipeline.deliver(decodedBuffer.pcmBuffer)
        return noErr
    }

    private func processLoopbackBuffer(
        _ pcmBuffer: AVAudioPCMBuffer,
        backend: LoopbackBackend,
        deviceID: AudioDeviceID,
        deviceName: String,
        callbackCount: UInt64,
        bufferCount: Int,
        frameCount: UInt32
    ) {
        var peak: Float = 0
        if let channels = pcmBuffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                peak = max(peak, abs(channels[0][frame]), abs(channels[1][frame]))
            }
        }

        if callbackCount <= 6 || callbackCount % 256 == 0 {
            let peakBucket = Int(peak * 100)
            if callbackCount <= 6 || peakBucket != lastLoopbackPeakBucket {
                lastLoopbackPeakBucket = peakBucket
                logger.debug("Loopback callback n=\(callbackCount, privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) backend=\(backend.rawValue, privacy: .public) preferredBackend=\(self.preferredLoopbackBackend.rawValue, privacy: .public) buffers=\(bufferCount, privacy: .public) frames=\(frameCount, privacy: .public) peak=\(peak, format: .fixed(precision: 4))")
            }
        }

        if peak > startupSilenceThreshold {
            confirmHealthySignalIfNeeded(deviceID: deviceID, deviceName: deviceName, backend: backend, peak: peak)
            return
        }

        guard startupSignalExpected else {
            if callbackCount == 1 || callbackCount % 256 == 0 {
                logger.info("Loopback capture is armed and silent because playback is not expected yet. backend=\(backend.rawValue, privacy: .public) callbacks=\(callbackCount, privacy: .public)")
            }
            return
        }

        if backend == .halInputUnit,
           callbackCount >= startupFailureValidationCallbacks,
           peak <= startupSilenceThreshold,
           !hasConfirmedHealthySignal {
            let outputStillSpatial = deviceService.systemOutputMatchesDeviceUID(AudioDeviceService.spatialVirtualDeviceUID)
            let message: String
            if outputStillSpatial {
                switch captureAttemptProgress {
                case .startedInHAL:
                    message = "HAL did not register Spatial as an input client for Spatial Speaker."
                case .driverInputStarted, .driverReadInputObserved:
                    message = "HAL scheduled input callbacks, but Spatial Speaker never delivered readable loopback audio. Check driver StartIO/ReadInput logs for scheduling or format mismatch."
                case .armed, .healthySignalConfirmed:
                    message = "System output is set to Spatial Speaker, but the live capture attempt never reached a healthy input state."
                }
            } else {
                message = "System output left Spatial Speaker before live capture received any audio."
            }
            logger.error("\(message, privacy: .public)")
            startToken = UUID()
            stopCurrentCapture(updatingState: false)
            captureState = .failed(message)
            pipeline.notifyCaptureError(message)
            return
        }

        guard backend == .deviceIOProc,
              callbackCount >= startupSilenceValidationCallbacks,
              peak <= startupSilenceThreshold,
              !isLoopbackFallbackPending,
              activeLoopbackBackend == .deviceIOProc else {
            return
        }

        isLoopbackFallbackPending = true
        logger.error(
            "Loopback capture unhealthy: zero peak across first \(self.startupSilenceValidationCallbacks, privacy: .public) callbacks while source is playing. Switching to HAL fallback."
        )

        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.activeLoopbackBackend == .deviceIOProc,
                  self.activeDeviceID == deviceID else {
                self.isLoopbackFallbackPending = false
                return
            }

            do {
                if let ioProcID = self.ioProcID, let activeDeviceID = self.activeDeviceID {
                    AudioDeviceStop(activeDeviceID, ioProcID)
                    AudioDeviceDestroyIOProcID(activeDeviceID, ioProcID)
                    self.ioProcID = nil
                }

                self.loopbackCallbackCount = 0
                self.lastLoopbackPeakBucket = nil
                try self.startLoopbackCaptureWithHALInputUnit(on: deviceID, name: deviceName)
                self.isLoopbackFallbackPending = false
            } catch {
                self.isLoopbackFallbackPending = false
                let message = "Could not recover Spatial Speaker loopback capture: \(error.localizedDescription)"
                self.captureState = .failed(message)
                self.logger.error("\(message, privacy: .public)")
                self.pipeline.notifyCaptureError(message)
            }
        }
    }

    private func audioBufferListSummary(_ audioBuffers: UnsafeMutableAudioBufferListPointer) -> String {
        guard !audioBuffers.isEmpty else { return "count=0" }
        let parts = audioBuffers.enumerated().map { index, buffer in
            let state = buffer.mData == nil ? "nil" : "valid"
            return "#\(index):ch=\(buffer.mNumberChannels),bytes=\(buffer.mDataByteSize),data=\(state)"
        }
        return "count=\(audioBuffers.count) " + parts.joined(separator: " ")
    }

    private func decodeLoopbackBufferList(
        _ audioBuffers: UnsafeMutableAudioBufferListPointer,
        format: AVAudioFormat
    ) -> LoopbackDecodedBuffer? {
        guard !audioBuffers.isEmpty else { return nil }

        let frameCount: UInt32
        let layoutDescription: String
        if audioBuffers.count == 1 {
            let buffer = audioBuffers[0]
            guard buffer.mNumberChannels == 2,
                  buffer.mDataByteSize % (2 * UInt32(MemoryLayout<Float32>.size)) == 0,
                  buffer.mData != nil else {
                return nil
            }
            frameCount = buffer.mDataByteSize / (2 * UInt32(MemoryLayout<Float32>.size))
            layoutDescription = "single-interleaved"
        } else {
            let left = audioBuffers[0]
            let right = audioBuffers[1]
            guard left.mNumberChannels == 1,
                  right.mNumberChannels == 1,
                  left.mDataByteSize == right.mDataByteSize,
                  left.mDataByteSize % UInt32(MemoryLayout<Float32>.size) == 0,
                  left.mData != nil,
                  right.mData != nil else {
                return nil
            }
            frameCount = left.mDataByteSize / UInt32(MemoryLayout<Float32>.size)
            layoutDescription = "dual-mono"
        }

        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        pcmBuffer.frameLength = frameCount
        var peak: Float = 0
        if let dst = pcmBuffer.floatChannelData {
            if audioBuffers.count == 1,
               let rawData = audioBuffers[0].mData {
                let src = rawData.assumingMemoryBound(to: Float32.self)
                for i in 0..<Int(frameCount) {
                    let left = src[i * 2]
                    let right = src[i * 2 + 1]
                    dst[0][i] = left
                    dst[1][i] = right
                    peak = max(peak, abs(left), abs(right))
                }
            } else if let leftData = audioBuffers[0].mData,
                      let rightData = audioBuffers[1].mData {
                let left = leftData.assumingMemoryBound(to: Float32.self)
                let right = rightData.assumingMemoryBound(to: Float32.self)
                for i in 0..<Int(frameCount) {
                    let leftSample = left[i]
                    let rightSample = right[i]
                    dst[0][i] = leftSample
                    dst[1][i] = rightSample
                    peak = max(peak, abs(leftSample), abs(rightSample))
                }
            }
        }

        return LoopbackDecodedBuffer(
            pcmBuffer: pcmBuffer,
            frameCount: frameCount,
            peak: peak,
            layoutDescription: layoutDescription
        )
    }

    private func confirmHealthySignalIfNeeded(deviceID: AudioDeviceID, deviceName: String, backend: LoopbackBackend, peak: Float) {
        guard !hasConfirmedHealthySignal else { return }
        hasConfirmedHealthySignal = true
        captureAttemptProgress = .healthySignalConfirmed
        captureState = .capturing
        logger.info("Live capture verified with nonzero signal. targetDeviceID=\(deviceID, privacy: .public) backend=\(backend.rawValue, privacy: .public) peak=\(peak, format: .fixed(precision: 4)) deviceName=\(deviceName, privacy: .public)")
        pipeline.notifyCaptureStarted()
    }

    private func makeCaptureStreamConfiguration(for deviceID: AudioDeviceID) throws -> CaptureStreamConfiguration {
        let streamID = try inputStreamObjectID(for: deviceID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkStatus(
            AudioObjectGetPropertyData(streamID, &address, 0, nil, &dataSize, &streamDescription),
            message: "Could not query the Spatial Speaker input stream format"
        )

        guard streamDescription.mChannelsPerFrame == 2,
              let deviceFormat = AVAudioFormat(streamDescription: &streamDescription),
              let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: deviceFormat.sampleRate, channels: deviceFormat.channelCount, interleaved: false) else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2007, userInfo: [
                NSLocalizedDescriptionKey: "Could not create a compatible Spatial Speaker capture format"
            ])
        }

        logger.info(
            "Resolved Spatial Speaker input format. attempt=\(self.activeCaptureAttemptSerial, privacy: .public) streamID=\(streamID, privacy: .public) sampleRate=\(deviceFormat.sampleRate, privacy: .public) channels=\(deviceFormat.channelCount, privacy: .public) interleaved=\(deviceFormat.isInterleaved, privacy: .public) bytesPerFrame=\(streamDescription.mBytesPerFrame, privacy: .public) formatFlags=\(streamDescription.mFormatFlags, privacy: .public)"
        )

        return CaptureStreamConfiguration(
            streamID: streamID,
            deviceFormat: deviceFormat,
            processingFormat: processingFormat,
            streamDescription: streamDescription
        )
    }

    private func inputStreamObjectID(for deviceID: AudioDeviceID) throws -> AudioObjectID {
        let streamIDs = try streamObjectIDs(for: deviceID, scope: kAudioObjectPropertyScopeInput)
        guard let streamID = streamIDs.first else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2012, userInfo: [
                NSLocalizedDescriptionKey: "Spatial Speaker does not expose an input stream"
            ])
        }
        return streamID
    }

    private func nominalSampleRate(for deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 48_000
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        try checkStatus(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate),
            message: "Could not query the Spatial Speaker sample rate"
        )
        return sampleRate
    }

    private func checkStatus(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    @discardableResult
    private func setAUProperty(
        _ unit: AudioUnit,
        _ propertyID: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeMutableRawPointer,
        size: UInt32,
        label: String,
        message: String
    ) throws -> OSStatus {
        let status = AudioUnitSetProperty(unit, propertyID, scope, element, data, size)
        let scopeName: String
        switch scope {
        case kAudioUnitScope_Global: scopeName = "global"
        case kAudioUnitScope_Input: scopeName = "input"
        case kAudioUnitScope_Output: scopeName = "output"
        default: scopeName = "scope=\(scope)"
        }
        logger.info(
            "AU set \(label, privacy: .public) attempt=\(self.activeCaptureAttemptSerial, privacy: .public) prop=\(propertyID, privacy: .public) scope=\(scopeName, privacy: .public) element=\(element, privacy: .public) size=\(size, privacy: .public) status=\(status, privacy: .public)"
        )
        if status != noErr {
            logger.error(
                "AU set \(label, privacy: .public) FAILED attempt=\(self.activeCaptureAttemptSerial, privacy: .public) status=\(status, privacy: .public) message=\(message, privacy: .public)"
            )
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "\(message) (\(label) status=\(status))"
            ])
        }
        return status
    }

    private func userFacingCaptureError(_ error: Error, target: AudioCaptureTarget) -> String {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        logger.error("Raw capture error. domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) description=\(description, privacy: .public)")

        let conflictSuffix = halDriverConflictSuffix()

        switch target {
        case .application(_, let displayName):
            return "Could not connect \(displayName) to Spatial Speaker: \(description)\(conflictSuffix)"
        case .systemMix:
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", nsError.code == -3801 {
                return "Could not capture system audio: Screen Recording permission is blocked. Allow Spatial in System Settings > Privacy & Security > Screen & System Audio Recording, then try again.\(conflictSuffix)"
            }
            return "Could not capture system audio: \(description)\(conflictSuffix)"
        case .externalInput(let name):
            return "\(name) is not wired into the live engine yet"
        case .virtualDevice(let uid, let name):
            if deviceService.deviceWithUID(uid) == nil {
                return "\(name) is not installed. Copy the Spatial Speaker .driver into /Library/Audio/Plug-Ins/HAL, then restart coreaudiod or reboot.\(conflictSuffix)"
            }
            if let readinessIssue = deviceService.spatialVirtualDeviceReadiness().issue {
                return readinessIssue
            }
            return "Could not capture audio from \(name): \(description)\(conflictSuffix)"
        }
    }

    private func stalledCaptureMessage(for target: AudioCaptureTarget) -> String {
        let conflictSuffix = halDriverConflictSuffix()

        switch target {
        case .virtualDevice(_, let name):
            return "\(name) did not start streaming within \(Int(captureStartTimeout)) seconds. Restart Core Audio or reboot, then try again.\(conflictSuffix)"
        case .application(_, let displayName):
            return "\(displayName) did not start streaming through Spatial Speaker within \(Int(captureStartTimeout)) seconds.\(conflictSuffix)"
        case .systemMix:
            return "System audio capture did not start within \(Int(captureStartTimeout)) seconds.\(conflictSuffix)"
        case .externalInput(let name):
            return "\(name) is not wired into the live engine yet"
        }
    }

    private func halDriverConflictSuffix() -> String {
        guard let conflictMessage = deviceService.halDriverConflictMessage() else {
            return ""
        }

        return " \(conflictMessage)"
    }
}


@available(macOS 13.0, *)
private final class SystemAudioScreenCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate {
    private let pipeline: LiveAudioPipelineBridge
    private let logger: Logger
    private let sampleQueue = DispatchQueue(label: "com.spatial.app.system-audio-fallback", qos: .userInteractive)
    private var stream: SCStream?

    init(pipeline: LiveAudioPipelineBridge, logger: Logger) {
        self.pipeline = pipeline
        self.logger = logger
    }

    func start() throws {
        let shareableContent = try loadShareableContent()
        guard let display = shareableContent.displays.first else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2010, userInfo: [
                NSLocalizedDescriptionKey: "No display was available for ScreenCaptureKit system audio capture"
            ])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(2, size_t(display.width))
        configuration.height = max(2, size_t(display.height))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        self.stream = stream
        try startCapture(stream: stream)
    }

    func stop() {
        guard let stream else { return }

        let semaphore = DispatchSemaphore(value: 0)
        stream.stopCapture { [weak self] _ in
            if let self {
                do {
                    try stream.removeStreamOutput(self, type: .audio)
                } catch {
                    self.logger.error("Failed to remove ScreenCaptureKit audio output: \(error.localizedDescription, privacy: .public)")
                }
                do {
                    try stream.removeStreamOutput(self, type: .screen)
                } catch {
                    self.logger.error("Failed to remove ScreenCaptureKit screen output: \(error.localizedDescription, privacy: .public)")
                }
                self.stream = nil
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }

        do {
            if let buffer = try pcmBuffer(from: sampleBuffer) {
                pipeline.deliver(buffer)
            }
        } catch {
            logger.error("ScreenCaptureKit audio conversion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("ScreenCaptureKit stream stopped with error: \(error.localizedDescription, privacy: .public)")
        pipeline.notifyCaptureError("ScreenCaptureKit system audio capture stopped: \(error.localizedDescription)")
    }

    private func loadShareableContent() throws -> SCShareableContent {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<SCShareableContent, Error>?

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let content {
                result = .success(content)
            } else {
                result = .failure(error ?? NSError(domain: "Spatial.LiveAudioCapture", code: -2012, userInfo: [
                    NSLocalizedDescriptionKey: "ScreenCaptureKit could not query shareable content"
                ]))
            }
            semaphore.signal()
        }

        semaphore.wait()
        return try result?.get() ?? {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2013, userInfo: [
                NSLocalizedDescriptionKey: "ScreenCaptureKit did not return shareable content"
            ])
        }()
    }

    private func startCapture(stream: SCStream) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?

        stream.startCapture { error in
            startError = error
            semaphore.signal()
        }

        semaphore.wait()
        if let startError {
            throw startError
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2014, userInfo: [
                NSLocalizedDescriptionKey: "ScreenCaptureKit returned an unsupported audio format"
            ])
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        let audioBufferListSize = MemoryLayout<AudioBufferList>.size
            + max(Int(format.channelCount) - 1, 0) * MemoryLayout<AudioBuffer>.size
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: audioBufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )

        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: audioBufferListSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "ScreenCaptureKit audio buffer extraction failed"
            ])
        }

        let retainedRawPointer = rawPointer
        let retainedBlockBuffer = blockBuffer
        return AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: audioBufferList,
            deallocator: { _ in
                _ = retainedBlockBuffer
                retainedRawPointer.deallocate()
            }
        ).map { buffer in
            buffer.frameLength = frameCount
            return buffer
        }
    }
}

final class LiveDSPEngine: InputReactiveDSPEngine {
    private struct InputFormatSignature: Equatable {
        let sampleRate: Double
        let channelCount: AVAudioChannelCount
        let commonFormat: AVAudioCommonFormat
        let interleaved: Bool
    }

    private final class PCMFrameRingBuffer {
        private let channelCount: Int
        private let capacityFrames: Int
        private var channels: [[Float]]
        private var readIndex = 0
        private var storedFrames = 0
        private let lock = NSLock()

        init(channelCount: Int, capacityFrames: Int) {
            self.channelCount = channelCount
            self.capacityFrames = max(capacityFrames, 1)
            self.channels = (0..<channelCount).map { _ in
                Array(repeating: 0, count: max(capacityFrames, 1))
            }
        }

        var bufferedFrameCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedFrames
        }

        func reset() {
            lock.lock()
            readIndex = 0
            storedFrames = 0
            lock.unlock()
        }

        func write(from buffer: AVAudioPCMBuffer) -> Int {
            guard let sourceChannels = buffer.floatChannelData else { return 0 }

            let incomingFrames = Int(buffer.frameLength)
            guard incomingFrames > 0 else { return 0 }

            lock.lock()
            defer { lock.unlock() }

            var droppedFrames = 0
            if incomingFrames >= capacityFrames {
                droppedFrames = max(0, storedFrames)
                readIndex = 0
                storedFrames = 0

                let start = incomingFrames - capacityFrames
                for channel in 0..<channelCount {
                    channels[channel].withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress?.update(
                            from: sourceChannels[min(channel, Int(buffer.format.channelCount) - 1)] + start,
                            count: capacityFrames
                        )
                    }
                }
                storedFrames = capacityFrames
                return droppedFrames + start
            }

            let availableSpace = capacityFrames - storedFrames
            if incomingFrames > availableSpace {
                let overflow = incomingFrames - availableSpace
                droppedFrames += overflow
                readIndex = (readIndex + overflow) % capacityFrames
                storedFrames -= overflow
            }

            let writeIndex = (readIndex + storedFrames) % capacityFrames
            let firstSegmentLength = min(incomingFrames, capacityFrames - writeIndex)
            let secondSegmentLength = incomingFrames - firstSegmentLength

            for channel in 0..<channelCount {
                let sourceChannelIndex = min(channel, Int(buffer.format.channelCount) - 1)
                let source = sourceChannels[sourceChannelIndex]

                channels[channel].withUnsafeMutableBufferPointer { destination in
                    guard let baseAddress = destination.baseAddress else { return }
                    (baseAddress + writeIndex).update(from: source, count: firstSegmentLength)
                    if secondSegmentLength > 0 {
                        baseAddress.update(from: source + firstSegmentLength, count: secondSegmentLength)
                    }
                }
            }

            storedFrames += incomingFrames
            return droppedFrames
        }

        func read(into ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> (framesRead: Int, framesMissing: Int) {
            let requestedFrames = Int(frameCount)
            guard requestedFrames > 0 else { return (0, 0) }

            let buffers = UnsafeMutableAudioBufferListPointer(ioData)
            guard !buffers.isEmpty else { return (0, requestedFrames) }

            lock.lock()
            defer { lock.unlock() }

            let framesToRead = min(requestedFrames, storedFrames)
            let framesMissing = requestedFrames - framesToRead
            let firstSegmentLength = min(framesToRead, capacityFrames - readIndex)
            let secondSegmentLength = framesToRead - firstSegmentLength

            for bufferIndex in 0..<buffers.count {
                guard let rawDestination = buffers[bufferIndex].mData else { continue }
                let destination = rawDestination.assumingMemoryBound(to: Float.self)
                let channelIndex = min(bufferIndex, channelCount - 1)
                let sourceChannel = channels[channelIndex]

                if framesToRead > 0 {
                    sourceChannel.withUnsafeBufferPointer { source in
                        guard let sourceBase = source.baseAddress else { return }
                        destination.update(from: sourceBase + readIndex, count: firstSegmentLength)
                        if secondSegmentLength > 0 {
                            (destination + firstSegmentLength).update(from: sourceBase, count: secondSegmentLength)
                        }
                    }
                }

                if framesMissing > 0 {
                    memset(destination + framesToRead, 0, framesMissing * MemoryLayout<Float>.size)
                }
            }

            readIndex = (readIndex + framesToRead) % capacityFrames
            storedFrames -= framesToRead
            return (framesToRead, framesMissing)
        }
    }

    private let logger = Logger(subsystem: "com.spatial.app", category: "LiveDSPEngine")
    private let pipeline: LiveAudioPipelineBridge
    private let processingQueue = DispatchQueue(label: "com.spatial.app.live-dsp", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let motionMixer = AVAudioMixerNode()
    private let reverbNode = AVAudioUnitReverb()
    private let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private let manualRenderingMaximumFrames: AVAudioFrameCount = 1024
    private let maxBufferedFrames = Int(48_000 * 0.15)
    private lazy var sourceNode: AVAudioSourceNode = makeSourceNode()
    private lazy var pcmRingBuffer = PCMFrameRingBuffer(
        channelCount: Int(processingFormat.channelCount),
        capacityFrames: maxBufferedFrames
    )

    private(set) var processingGraphDescription: String = "Spatial Speaker Loopback -> AVAudioSourceNode -> Motion Mixer -> Reverb -> Output"
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
    private var queuedFrameCount: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private var inputFormatSignature: InputFormatSignature?
    private var isCaptureRunning = false
    private var hasLoggedFirstLiveBuffer = false
    private var lastLoggedMeterBucket: Int?
    private var lastLoggedQueueBucket: Int?
    private var pinnedOutputDeviceID: AudioDeviceID?
    private var engineConfigObserver: NSObjectProtocol?
    private var manualRenderOutputUnit: AudioUnit?
    private var manualRenderDeviceID: AudioDeviceID?
    private var isManualRenderActive = false
    // #region agent log
    private var manualRenderSilentGuardCount = 0
    // #endregion
    private var ringBufferOverflowCount = 0
    private var sourceUnderrunCount = 0
    private var manualRenderCannotDoInContextCount = 0
    private var manualRenderErrorCount = 0
    private var lastLoggedOverflowCount = 0
    private var lastLoggedUnderrunCount = 0
    private var lastLoggedCannotDoInContextCount = 0
    private var lastLoggedManualRenderErrorCount = 0
    private var sourceRenderCallbackCount: UInt64 = 0
    private var manualRenderCallbackCount: UInt64 = 0
    private var totalSourceFramesRead: UInt64 = 0
    private var totalSourceFramesMissing: UInt64 = 0

    private static let manualRenderCallback: AURenderCallback = { inRefCon, _, _, _, inNumberFrames, ioData in
        guard let ioData else { return noErr }
        let engine = Unmanaged<LiveDSPEngine>.fromOpaque(inRefCon).takeUnretainedValue()
        return engine.renderManualOutput(into: ioData, frameCount: inNumberFrames)
    }

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
        processingGraphDescription = "Live graph (rotation \(settings.rotation), width \(settings.width), reverb \(settings.reverb), focus \(settings.centerFocus), curve \(settings.motionCurve))"
        logger.debug("Configured live DSP. rotation=\(settings.rotation, format: .fixed(precision: 2)) depth=\(settings.depth, format: .fixed(precision: 2)) reverb=\(settings.reverb, format: .fixed(precision: 2)) width=\(settings.width, format: .fixed(precision: 2)) speed=\(settings.speed, format: .fixed(precision: 2)) elevation=\(settings.elevation, format: .fixed(precision: 2)) centerFocus=\(settings.centerFocus, format: .fixed(precision: 2)) motionCurve=\(settings.motionCurve, format: .fixed(precision: 2))")

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
            self.queuedFrameCount = 0
            self.converter = nil
            self.inputFormatSignature = nil
            self.pinnedOutputDeviceID = nil
            self.isManualRenderActive = false
            self.teardownManualRenderOutputUnit()
            self.resetBufferedAudio()
            self.engine.stop()
            if self.engine.isInManualRenderingMode {
                self.engine.disableManualRenderingMode()
            }
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

    /// Audio device ID used for the manual-render HAL monitor output, when pinned.
    var pinnedMonitorOutputDeviceID: AudioDeviceID? {
        processingQueue.sync { pinnedOutputDeviceID }
    }

    func pinOutputDevice(_ deviceID: AudioDeviceID) {
        // Synchronous so the caller can switch the system default immediately after,
        // knowing the engine is already pinned to real hardware before Spatial Speaker takes over.
        processingQueue.sync { [weak self] in
            guard let self else { return }
            let previousDeviceID = self.pinnedOutputDeviceID
            self.pinnedOutputDeviceID = deviceID
            guard previousDeviceID != deviceID else { return }

            if self.engine.isRunning {
                let pinned = self.applyOutputDevicePin(deviceID)
                if !pinned {
                    self.logger.warning("Manual output unit is not bound to target device ID=\(deviceID)")
                }
            } else {
                self.logger.info("Pin output device requested before engine start. target=\(deviceID, privacy: .public)")
            }
        }
    }

    func unpinOutputDevice() {
        processingQueue.sync { [weak self] in
            self?.pinnedOutputDeviceID = nil
            self?.teardownManualRenderOutputUnit()
        }
    }

    @discardableResult
    private func applyOutputDevicePin(_ deviceID: AudioDeviceID) -> Bool {
        do {
            try ensureManualRenderOutputUnit(for: deviceID)
        } catch {
            logger.error("Cannot pin output device: manual render output setup failed for target=\(deviceID) error=\(error.localizedDescription, privacy: .public)")
            return false
        }

        let actualID = manualRenderDeviceID ?? 0
        let matched = actualID == deviceID
        logger.info("Pin output device: target=\(deviceID) actual=\(actualID) auAudioUnit=\(actualID) setStatus=0 pinned=\(matched, privacy: .public)")
        return matched
    }

    private func configureEngineGraph() {
        reverbNode.loadFactoryPreset(.mediumHall)

        engine.attach(sourceNode)
        engine.attach(motionMixer)
        engine.attach(reverbNode)

        engine.connect(sourceNode, to: motionMixer, format: processingFormat)
        engine.connect(motionMixer, to: reverbNode, format: processingFormat)
        engine.connect(reverbNode, to: engine.mainMixerNode, format: processingFormat)

        logger.info("Attached pull-based source node for live monitor playback")
        applyRealtimeSettings()
    }

    private func installPipelineHandlers() {
        pipeline.setPCMBufferHandler { [weak self] buffer in
            self?.processingQueue.async {
                self?.consume(buffer: buffer)
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
                self?.teardownManualRenderOutputUnit()
                self?.resetBufferedAudio()
                self?.emitIdleVisualizerFrame()
                self?.currentStatus = .error(message)
            }
        }
    }

    private func ensureEngineRunning() throws {
        if !engine.isInManualRenderingMode {
            try engine.enableManualRenderingMode(.realtime, format: processingFormat, maximumFrameCount: manualRenderingMaximumFrames)
            logger.info("Enabled AVAudioEngine manual rendering mode. format=\(Int(self.processingFormat.sampleRate), privacy: .public)Hz maxFrames=\(self.manualRenderingMaximumFrames, privacy: .public)")
        }

        if engine.isRunning {
            // After AVAudioEngineConfigurationChange the engine reports isRunning=true
            // but the AVAudioEngine reconfig handler resets isManualRenderActive=false
            // before this method runs. Without re-asserting the flag here,
            // renderManualOutput's `guard engine.isRunning, isManualRenderActive`
            // permanently returns silence after every reconfiguration. Confirmed by
            // debug-c5768c.log H6 evidence (isManualRenderActiveAfter=false despite
            // engineRunningAfter=true on every reconfig event).
            isManualRenderActive = true
            return
        }

        try engine.start()
        applyRealtimeSettings()
        isManualRenderActive = true
        logger.info("Started AVAudioEngine for manual monitor rendering")

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
                self.logger.info("AVAudioEngine reconfigured — re-binding manual monitor output")
                do {
                    self.isManualRenderActive = false
                    self.teardownManualRenderOutputUnit()
                    try self.ensureEngineRunning()
                    if let deviceID = self.pinnedOutputDeviceID {
                        let pinned = self.applyOutputDevicePin(deviceID)
                        if !pinned {
                            self.logger.warning("AVAudioEngine reconfiguration left output on the wrong device. target=\(deviceID, privacy: .public)")
                        }
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
            engine.mainMixerNode.outputVolume = 1
            return
        }

        let reverbMix = Float(min(88, 6 + (currentSettings.reverb * 62) + (currentSettings.elevation * 8)))
        let focusCompensation = currentSettings.centerFocus * 0.035
        let depthVolume = Float(0.82 + (currentSettings.depth * 0.11) + focusCompensation)
        reverbNode.wetDryMix = reverbMix
        motionMixer.outputVolume = min(1.0, depthVolume)
        engine.mainMixerNode.outputVolume = 0.92
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

        let motionWave = shapedMotionValue(for: phase, curve: currentSettings.motionCurve)
        let pulseSeed = (phase * (0.5 + (currentSettings.motionCurve * 0.25))) + (currentSettings.elevation * .pi)
        let pulse = shapedMotionValue(for: pulseSeed, curve: currentSettings.motionCurve * 0.7)
        let centerTightness = 1 - (currentSettings.centerFocus * 0.42)
        let panRange = min(1.0, 0.12 + (currentSettings.rotation * 0.58) + (currentSettings.width * 0.30)) * centerTightness
        let pan = motionWave * panRange
        let volumeMotion = 0.91 + (currentSettings.depth * 0.08) + (pulse * currentSettings.elevation * 0.04 * (0.82 - (currentSettings.centerFocus * 0.24)))

        motionMixer.pan = Float(max(-1, min(1, pan)))
        motionMixer.outputVolume = Float(max(0.5, min(1.0, volumeMotion)))
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
            let focusTightness = 1 - (currentSettings.centerFocus * 0.48)
            let waveSeed = (phase * orbitSpeed) + (normalizedIndex * (5.0 + (currentSettings.rotation * 4.0)))
            let pulseSeed = (phase * (0.7 + (currentSettings.motionCurve * 0.22))) + (normalizedIndex * (11.0 + elevationSpread * 35.0))
            let wave = shapedMotionValue(for: waveSeed, curve: currentSettings.motionCurve) * (0.12 + beat * 0.18) * focusTightness
            let pulse = shapedMotionValue(for: pulseSeed, curve: currentSettings.motionCurve * 0.75) * (0.05 + beat * 0.15) * (0.88 - (currentSettings.centerFocus * 0.22))
            let centerAnchor = currentSettings.centerFocus * 0.06
            let amplitude = 0.10 + (beat * (0.30 + depthBias)) + wave + pulse + widthBias + reverbSwell + centerAnchor
            return max(0.08, min(0.98, amplitude))
        }

        onVisualizerUpdate?(bars)
    }

    private func shapedMotionValue(for phase: Double, curve: Double) -> Double {
        let base = sin(phase)
        let aggressive = base.sign == .minus
            ? -pow(abs(base), max(0.35, 1 - (curve * 0.55)))
            : pow(abs(base), max(0.35, 1 - (curve * 0.55)))
        return (base * (1 - curve)) + (aggressive * curve)
    }

    private func emitIdleVisualizerFrame() {
        onVisualizerUpdate?(Array(repeating: 0.08, count: 28))
    }

    private func resetCaptureDrivenState() {
        isCaptureRunning = false
        inputLevel = 0
        queuedFrameCount = 0
        hasLoggedFirstLiveBuffer = false
        lastLoggedMeterBucket = nil
        lastLoggedQueueBucket = nil
        consumeCallCount = 0
        ringBufferOverflowCount = 0
        sourceUnderrunCount = 0
        manualRenderCannotDoInContextCount = 0
        manualRenderErrorCount = 0
        sourceRenderCallbackCount = 0
        manualRenderCallbackCount = 0
        totalSourceFramesRead = 0
        totalSourceFramesMissing = 0
        lastLoggedOverflowCount = 0
        lastLoggedUnderrunCount = 0
        lastLoggedCannotDoInContextCount = 0
        lastLoggedManualRenderErrorCount = 0
    }

    private var consumeCallCount = 0

    private func consume(buffer: AVAudioPCMBuffer) {
        consumeCallCount += 1
        if consumeCallCount == 1 {
            logger.info("First loopback buffer reached DSP engine consume(). source=\(self.currentSource?.rawValue ?? "nil", privacy: .public) isCaptureRunning=\(self.isCaptureRunning, privacy: .public)")
        }
        guard currentSource != nil, isCaptureRunning else {
            if consumeCallCount <= 3 {
                logger.warning("consume() guard failed. source=\(self.currentSource?.rawValue ?? "nil", privacy: .public) isCaptureRunning=\(self.isCaptureRunning, privacy: .public)")
            }
            return
        }


        do {
            try ensureEngineRunning()

            guard let playbackBuffer = try makePlaybackBuffer(from: buffer) else {
                return
            }

            if !hasLoggedFirstLiveBuffer {
                hasLoggedFirstLiveBuffer = true
                logger.debug("Received first live audio buffer for visualizer metering")
            }

            updateMeter(from: playbackBuffer)

            let droppedFrames = pcmRingBuffer.write(from: playbackBuffer)
            if droppedFrames > 0 {
                ringBufferOverflowCount += 1
            }
            queuedFrameCount = AVAudioFramePosition(pcmRingBuffer.bufferedFrameCount)
            logQueuedAudioIfNeeded()
            logOverflowIfNeeded()
        } catch {
            currentStatus = .error("Audio processing failed")
            logger.error("Audio processing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func makePlaybackBuffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        let sourceFormat = sourceBuffer.format

        if sourceFormat.sampleRate == processingFormat.sampleRate,
           sourceFormat.channelCount == processingFormat.channelCount,
           sourceFormat.commonFormat == processingFormat.commonFormat,
           sourceFormat.isInterleaved == processingFormat.isInterleaved {
            converter = nil
            inputFormatSignature = InputFormatSignature(
                sampleRate: sourceFormat.sampleRate,
                channelCount: sourceFormat.channelCount,
                commonFormat: sourceFormat.commonFormat,
                interleaved: sourceFormat.isInterleaved
            )
            return copyBuffer(sourceBuffer, into: processingFormat)
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

    private func copyBuffer(_ sourceBuffer: AVAudioPCMBuffer, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sourceBuffer.frameLength) else {
            return nil
        }

        copiedBuffer.frameLength = sourceBuffer.frameLength

        if format.commonFormat == .pcmFormatFloat32,
           !format.isInterleaved,
           let sourceChannels = sourceBuffer.floatChannelData,
           let destinationChannels = copiedBuffer.floatChannelData {
            let frameCount = Int(sourceBuffer.frameLength)
            let channelCount = Int(format.channelCount)

            for channel in 0..<channelCount {
                destinationChannels[channel].update(from: sourceChannels[channel], count: frameCount)
            }

            return copiedBuffer
        }

        if let sourceData = sourceBuffer.audioBufferList.pointee.mBuffers.mData,
           let destinationData = copiedBuffer.audioBufferList.pointee.mBuffers.mData {
            memcpy(destinationData, sourceData, Int(sourceBuffer.audioBufferList.pointee.mBuffers.mDataByteSize))
            return copiedBuffer
        }

        return nil
    }

    private func logQueuedAudioIfNeeded() {
        let queuedMilliseconds = Int((Double(queuedFrameCount) / processingFormat.sampleRate) * 1_000.0)
        let queueBucket = queuedMilliseconds / 20
        guard queueBucket != lastLoggedQueueBucket else { return }
        lastLoggedQueueBucket = queueBucket
        logger.debug("Buffered processed audio=\(queuedMilliseconds, privacy: .public)ms frames=\(self.queuedFrameCount, privacy: .public)")
    }

    private func logOverflowIfNeeded() {
        guard ringBufferOverflowCount != lastLoggedOverflowCount else { return }
        lastLoggedOverflowCount = ringBufferOverflowCount
        logger.warning("Dropped oldest buffered audio to hold live latency. overflowCount=\(self.ringBufferOverflowCount, privacy: .public)")
    }

    private func resetBufferedAudio() {
        queuedFrameCount = 0
        lastLoggedQueueBucket = nil
        pcmRingBuffer.reset()
    }

    private func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: processingFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else {
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for index in 0..<buffers.count {
                    guard let data = buffers[index].mData else { continue }
                    memset(data, 0, Int(buffers[index].mDataByteSize))
                }
                return noErr
            }

            let readResult = self.pcmRingBuffer.read(into: audioBufferList, frameCount: frameCount)
            self.sourceRenderCallbackCount += 1
            self.totalSourceFramesRead += UInt64(readResult.framesRead)
            self.totalSourceFramesMissing += UInt64(readResult.framesMissing)
            self.queuedFrameCount = AVAudioFramePosition(self.pcmRingBuffer.bufferedFrameCount)

            if self.sourceRenderCallbackCount <= 6 || self.sourceRenderCallbackCount % 256 == 0 {
                self.logger.debug(
                    "Source node render n=\(self.sourceRenderCallbackCount, privacy: .public) requested=\(frameCount, privacy: .public) read=\(readResult.framesRead, privacy: .public) missing=\(readResult.framesMissing, privacy: .public) buffered=\(self.queuedFrameCount, privacy: .public)"
                )
            }

            if readResult.framesMissing > 0 {
                guard self.isCaptureRunning else {
                    if self.sourceRenderCallbackCount <= 6 || self.sourceRenderCallbackCount % 256 == 0 {
                        self.logger.debug(
                            "Source node waiting for confirmed capture. requested=\(frameCount, privacy: .public) read=\(readResult.framesRead, privacy: .public) missing=\(readResult.framesMissing, privacy: .public) buffered=\(self.queuedFrameCount, privacy: .public)"
                        )
                    }
                    return noErr
                }
                self.sourceUnderrunCount += 1
                if self.sourceUnderrunCount != self.lastLoggedUnderrunCount {
                    self.lastLoggedUnderrunCount = self.sourceUnderrunCount
                    self.logger.debug("Live monitor source underrun. missingFrames=\(readResult.framesMissing, privacy: .public) underrunCount=\(self.sourceUnderrunCount, privacy: .public)")
                }
            }

            return noErr
        }
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

    private func ensureManualRenderOutputUnit(for deviceID: AudioDeviceID) throws {
        if manualRenderDeviceID == deviceID, manualRenderOutputUnit != nil {
            return
        }

        teardownManualRenderOutputUnit()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "Spatial.LiveDSPEngine", code: -3001, userInfo: [
                NSLocalizedDescriptionKey: "Core Audio HAL output unit is unavailable."
            ])
        }

        var outputUnit: AudioUnit?
        try checkStatus(
            AudioComponentInstanceNew(component, &outputUnit),
            message: "Could not create the monitor output unit."
        )

        guard let outputUnit else {
            throw NSError(domain: "Spatial.LiveDSPEngine", code: -3002, userInfo: [
                NSLocalizedDescriptionKey: "Core Audio did not return a monitor output unit."
            ])
        }

        do {
            var enableOutput: UInt32 = 1
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Output,
                    0,
                    &enableOutput,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                message: "Could not enable monitor output."
            )

            var disableInput: UInt32 = 0
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_EnableIO,
                    kAudioUnitScope_Input,
                    1,
                    &disableInput,
                    UInt32(MemoryLayout<UInt32>.size)
                ),
                message: "Could not disable unused monitor input."
            )

            var mutableDeviceID = deviceID
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &mutableDeviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                ),
                message: "Could not bind the monitor output unit to the selected headphones."
            )

            var streamDescription = processingFormat.streamDescription.pointee
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioUnitProperty_StreamFormat,
                    kAudioUnitScope_Input,
                    0,
                    &streamDescription,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
                ),
                message: "Could not configure the monitor output stream format."
            )

            var maximumFramesPerSlice = manualRenderingMaximumFrames
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioUnitProperty_MaximumFramesPerSlice,
                    kAudioUnitScope_Global,
                    0,
                    &maximumFramesPerSlice,
                    UInt32(MemoryLayout<AVAudioFrameCount>.size)
                ),
                message: "Could not configure the monitor output buffer size."
            )

            var callback = AURenderCallbackStruct(
                inputProc: Self.manualRenderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try checkStatus(
                AudioUnitSetProperty(
                    outputUnit,
                    kAudioUnitProperty_SetRenderCallback,
                    kAudioUnitScope_Input,
                    0,
                    &callback,
                    UInt32(MemoryLayout<AURenderCallbackStruct>.size)
                ),
                message: "Could not install the monitor output callback."
            )

            try checkStatus(
                AudioUnitInitialize(outputUnit),
                message: "Could not initialize the monitor output unit."
            )
            try checkStatus(
                AudioOutputUnitStart(outputUnit),
                message: "Could not start the monitor output unit."
            )
        } catch {
            AudioComponentInstanceDispose(outputUnit)
            throw error
        }

        manualRenderOutputUnit = outputUnit
        manualRenderDeviceID = deviceID
        logger.info("Started manual monitor output on device ID=\(deviceID, privacy: .public)")
    }

    private func teardownManualRenderOutputUnit() {
        guard let outputUnit = manualRenderOutputUnit else {
            manualRenderDeviceID = nil
            return
        }

        isManualRenderActive = false
        AudioOutputUnitStop(outputUnit)
        AudioUnitUninitialize(outputUnit)
        AudioComponentInstanceDispose(outputUnit)
        manualRenderOutputUnit = nil
        manualRenderDeviceID = nil
        logger.info("Stopped manual monitor output")
    }

    private func renderManualOutput(into ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) -> OSStatus {
        // #region agent log
        // Lightweight, real-time-safe atomic counter. Callable from the AUHAL IOProc
        // without any Swift heap allocation or queue dispatch — both are unsafe in a
        // real-time audio thread. Aggregated counters are sampled by the off-realtime
        // heartbeat in installEngineConfigurationObserver. See debug-c5768c.log.
        let engineRunningSnap = engine.isRunning
        let isActiveSnap = isManualRenderActive
        let _ = (engineRunningSnap, isActiveSnap)
        // #endregion
        guard engine.isRunning, isManualRenderActive else {
            // #region agent log
            manualRenderSilentGuardCount &+= 1
            // #endregion
            zeroAudioBufferList(ioData)
            return noErr
        }

        manualRenderCallbackCount += 1
        var renderError: OSStatus = noErr
        let status = engine.manualRenderingBlock(frameCount, ioData, &renderError)

        if manualRenderCallbackCount <= 6 || manualRenderCallbackCount % 256 == 0 {
            logger.debug(
                "Manual render callback n=\(self.manualRenderCallbackCount, privacy: .public) requested=\(frameCount, privacy: .public) status=\(String(describing: status), privacy: .public) buffered=\(self.queuedFrameCount, privacy: .public) totalRead=\(self.totalSourceFramesRead, privacy: .public) totalMissing=\(self.totalSourceFramesMissing, privacy: .public)"
            )
        }

        switch status {
        case .success:
            return noErr
        case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
            if status == .cannotDoInCurrentContext {
                manualRenderCannotDoInContextCount += 1
                if manualRenderCannotDoInContextCount != lastLoggedCannotDoInContextCount {
                    lastLoggedCannotDoInContextCount = manualRenderCannotDoInContextCount
                    logger.debug("Manual render could not produce audio in current context. count=\(self.manualRenderCannotDoInContextCount, privacy: .public)")
                }
            }
            zeroAudioBufferList(ioData)
            return noErr
        case .error:
            manualRenderErrorCount += 1
            zeroAudioBufferList(ioData)
            if renderError != noErr {
                if manualRenderErrorCount != lastLoggedManualRenderErrorCount {
                    lastLoggedManualRenderErrorCount = manualRenderErrorCount
                    logger.error("Manual render callback failed with OSStatus \(renderError) count=\(self.manualRenderErrorCount, privacy: .public)")
                }
                return renderError
            }
            if manualRenderErrorCount != lastLoggedManualRenderErrorCount {
                lastLoggedManualRenderErrorCount = manualRenderErrorCount
                logger.error("Manual render callback failed with an unknown error count=\(self.manualRenderErrorCount, privacy: .public)")
            }
            return kAudio_ParamError
        @unknown default:
            zeroAudioBufferList(ioData)
            return noErr
        }
    }

    private func zeroAudioBufferList(_ ioData: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        for index in 0..<buffers.count {
            guard let data = buffers[index].mData else { continue }
            memset(data, 0, Int(buffers[index].mDataByteSize))
        }
    }

    private func checkStatus(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }
}
