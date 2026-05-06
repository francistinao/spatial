import Foundation

struct AppEnvironment {
    let audioCaptureService: AudioCaptureService
    let audioSourceResolver: AudioSourceResolving
    let dspEngine: DSPEngine
    let demoPlaybackService: DemoPlaybackService
    let playbackMetadataService: PlaybackMetadataService
    let launchAtLoginService: LaunchAtLoginService
    let presetStore: PresetStore
    let settingsStore: SettingsStore
    let outputDeviceObserver: OutputDeviceObserving
    let virtualAudioRoutingService: VirtualAudioRoutingService
    let audioDeviceService: AudioDeviceService
    let permissionsService: PermissionsService
    let driverInstaller: SpatialDriverInstalling

    static func makeDefault() -> AppEnvironment {
        let settingsStore = InMemorySettingsStore()
        let presetStore = InMemoryPresetStore()
        let livePipeline = LiveAudioPipelineBridge()
        let liveDSPEngine = LiveDSPEngine(pipeline: livePipeline)
        let audioDeviceService = AudioDeviceService()
        let virtualAudioRoutingService = SpatialVirtualAudioRoutingService(deviceService: audioDeviceService)
        let driverInstaller = BundledSpatialDriverInstaller()
        virtualAudioRoutingService.restoreOnLaunchIfNeeded()

        return AppEnvironment(
            audioCaptureService: LiveAudioCaptureService(pipeline: livePipeline, deviceService: audioDeviceService),
            audioSourceResolver: DefaultAudioSourceResolver(),
            dspEngine: liveDSPEngine,
            demoPlaybackService: SystemDemoPlaybackService(),
            playbackMetadataService: StubPlaybackMetadataService(),
            launchAtLoginService: StubLaunchAtLoginService(),
            presetStore: presetStore,
            settingsStore: settingsStore,
            outputDeviceObserver: StubOutputDeviceObserver(),
            virtualAudioRoutingService: virtualAudioRoutingService,
            audioDeviceService: audioDeviceService,
            permissionsService: SystemAudioPermissionsService(),
            driverInstaller: driverInstaller
        )
    }
}
