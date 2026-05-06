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

final class LiveAudioCaptureService: NSObject, AudioCaptureService {
    private let logger = Logger(subsystem: "com.spatial.app", category: "LiveAudioCapture")
    private let captureStartTimeout: TimeInterval = 6
    private let pipeline: LiveAudioPipelineBridge
    private let deviceService: AudioDeviceService
    private let captureQueue = DispatchQueue(label: "com.spatial.app.device-capture", qos: .userInteractive)
    private var audioUnit: AudioUnit?
    private var screenCaptureSession: SystemAudioScreenCaptureSession?
    private var activeDeviceID: AudioDeviceID?
    private var captureFormat: AVAudioFormat?
    private var startToken = UUID()

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
        logger.debug("Beginning live capture setup for target: \(String(describing: target), privacy: .public)")
        stopCurrentCapture(updatingState: false)

        do {
            try beginDeviceCapture(for: target)
            guard token == startToken else { return }

            captureState = .capturing
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

    private func scheduleCaptureStartTimeout(for target: AudioCaptureTarget, token: UUID) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + captureStartTimeout) { [weak self] in
            self?.handleCaptureStartTimeout(for: target, token: token)
        }
    }

    private func handleCaptureStartTimeout(for target: AudioCaptureTarget, token: UUID) {
        guard token == startToken, captureState == .armed else { return }

        startToken = UUID()
        let message = stalledCaptureMessage(for: target)
        captureState = .failed(message)
        logger.error("Live capture timed out before stream started: \(message, privacy: .public)")
        pipeline.notifyCaptureError(message)
    }

    private func stopCurrentCapture(updatingState: Bool) {
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
            AudioUnitUninitialize(audioUnit)
            AudioComponentInstanceDispose(audioUnit)
            self.audioUnit = nil
            self.activeDeviceID = nil
            self.captureFormat = nil
            logger.info("Stopped device-backed live capture")
        }

        if let screenCaptureSession {
            screenCaptureSession.stop()
            self.screenCaptureSession = nil
            logger.info("Stopped ScreenCaptureKit system audio capture")
        }

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
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2005, userInfo: [
                NSLocalizedDescriptionKey: "Core Audio HAL output unit is unavailable"
            ])
        }

        var audioUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &audioUnit) == noErr, let audioUnit else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2006, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the Spatial Speaker capture unit"
            ])
        }

        do {
            var enableInput: UInt32 = 1
            var disableOutput: UInt32 = 0
            try checkStatus(
                AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size)),
                message: "Could not enable Spatial Speaker capture input"
            )
            try checkStatus(
                AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size)),
                message: "Could not disable direct output on the capture unit"
            )

            var mutableDeviceID = deviceID
            try checkStatus(
                AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &mutableDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size)),
                message: "Could not bind capture to Spatial Speaker"
            )

            let streamFormat = try makeCaptureStreamFormat(for: deviceID)
            var asbd = streamFormat.streamDescription.pointee
            try checkStatus(
                AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
                message: "Could not configure Spatial Speaker stream format"
            )

            var callback = AURenderCallbackStruct(
                inputProc: liveCaptureInputCallback,
                inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            )
            try checkStatus(
                AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                message: "Could not install the Spatial Speaker input callback"
            )

            try checkStatus(AudioUnitInitialize(audioUnit), message: "Could not initialize Spatial Speaker capture")
            try checkStatus(AudioOutputUnitStart(audioUnit), message: "Could not start Spatial Speaker capture")

            self.audioUnit = audioUnit
            self.activeDeviceID = deviceID
            self.captureFormat = streamFormat
            logger.info("Loopback capture armed on device '\(name, privacy: .public)' id=\(deviceID)")
        } catch {
            AudioComponentInstanceDispose(audioUnit)
            throw error
        }
    }

    private func makeCaptureStreamFormat(for deviceID: AudioDeviceID) throws -> AVAudioFormat {
        let sampleRate = try nominalSampleRate(for: deviceID)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false) else {
            throw NSError(domain: "Spatial.LiveAudioCapture", code: -2007, userInfo: [
                NSLocalizedDescriptionKey: "Could not create the Spatial Speaker capture format"
            ])
        }

        return format
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

    fileprivate func handleInput(frameCount: UInt32, ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>) -> OSStatus {
        guard let audioUnit, let captureFormat else {
            return noErr
        }

        let channelCount = Int(captureFormat.channelCount)
        let bytesPerChannel = Int(frameCount) * MemoryLayout<Float>.size
        let audioBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        audioBufferList.pointee.mNumberBuffers = UInt32(channelCount)
        let bufferListPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

        for index in 0..<channelCount {
            bufferListPointer[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(bytesPerChannel),
                mData: UnsafeMutableRawPointer.allocate(byteCount: bytesPerChannel, alignment: MemoryLayout<Float>.alignment)
            )
        }

        defer {
            for buffer in bufferListPointer where buffer.mData != nil {
                buffer.mData?.deallocate()
            }
            audioBufferList.deallocate()
        }

        let status = AudioUnitRender(audioUnit, ioActionFlags, timeStamp, 1, frameCount, audioBufferList)
        guard status == noErr else {
            logger.error("AudioUnitRender failed for Spatial Speaker capture. status=\(status)")
            return status
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: frameCount) else {
            return noErr
        }

        pcmBuffer.frameLength = frameCount
        if let destination = pcmBuffer.floatChannelData {
            for channel in 0..<channelCount {
                if let source = bufferListPointer[channel].mData {
                    memcpy(destination[channel], source, bytesPerChannel)
                }
            }
        }

        pipeline.deliver(pcmBuffer)
        return noErr
    }

    private func checkStatus(_ status: OSStatus, message: String) throws {
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
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

private let liveCaptureInputCallback: AURenderCallback = { inRefCon, ioActionFlags, inTimeStamp, _, inNumberFrames, _ in
    let service = Unmanaged<LiveAudioCaptureService>.fromOpaque(inRefCon).takeUnretainedValue()
    return service.handleInput(frameCount: inNumberFrames, ioActionFlags: ioActionFlags, timeStamp: inTimeStamp)
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

    private let logger = Logger(subsystem: "com.spatial.app", category: "LiveDSPEngine")
    private let pipeline: LiveAudioPipelineBridge
    private let processingQueue = DispatchQueue(label: "com.spatial.app.live-dsp", qos: .userInitiated)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let motionMixer = AVAudioMixerNode()
    private let reverbNode = AVAudioUnitReverb()
    private let processingFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    private(set) var processingGraphDescription: String = "Spatial Speaker Loopback -> AVAudioPlayerNode -> Motion Mixer -> Reverb -> Output"
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
    private let maxQueuedFrames: AVAudioFramePosition = 1_920
    private let queueResyncFrames: AVAudioFramePosition = 1_440

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
            self.queuedFrameCount = 0
            self.converter = nil
            self.inputFormatSignature = nil
            self.pinnedOutputDeviceID = nil
            self.resetScheduledAudioQueue()
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
        // knowing the engine is already pinned to real hardware before Spatial Speaker takes over.
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
        queuedFrameCount = 0
        hasLoggedFirstLiveBuffer = false
        lastLoggedMeterBucket = nil
        lastLoggedQueueBucket = nil
        consumeCallCount = 0
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

            if queuedFrameCount >= maxQueuedFrames {
                logger.debug("Dropping captured buffer to keep latency bounded. queuedFrames=\(self.queuedFrameCount, privacy: .public)")
                return
            }

            guard let playbackBuffer = try makePlaybackBuffer(from: buffer) else {
                return
            }

            if !hasLoggedFirstLiveBuffer {
                hasLoggedFirstLiveBuffer = true
                logger.debug("Received first live audio buffer for visualizer metering")
            }

            updateMeter(from: playbackBuffer)
            if queuedFrameCount >= queueResyncFrames {
                logger.info("Resetting scheduled audio queue to reduce latency. queuedFrames=\(self.queuedFrameCount, privacy: .public)")
                resetScheduledAudioQueue()
            }

            let scheduledFrames = AVAudioFramePosition(playbackBuffer.frameLength)
            queuedFrameCount += scheduledFrames
            logQueuedAudioIfNeeded()

            playerNode.scheduleBuffer(playbackBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                self?.processingQueue.async {
                    guard let self else { return }
                    self.queuedFrameCount = max(0, self.queuedFrameCount - scheduledFrames)
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
            return sourceBuffer
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

    private func logQueuedAudioIfNeeded() {
        let queuedMilliseconds = Int((Double(queuedFrameCount) / processingFormat.sampleRate) * 1_000.0)
        let queueBucket = queuedMilliseconds / 10
        guard queueBucket != lastLoggedQueueBucket else { return }
        lastLoggedQueueBucket = queueBucket
        logger.debug("Queued processed audio=\(queuedMilliseconds, privacy: .public)ms frames=\(self.queuedFrameCount, privacy: .public)")
    }

    private func resetScheduledAudioQueue() {
        queuedFrameCount = 0
        lastLoggedQueueBucket = nil
        playerNode.stop()
        playerNode.reset()
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
