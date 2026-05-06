import Foundation

struct AppEnvironment {
    let audioCaptureService: AudioCaptureService
    let audioSourceResolver: AudioSourceResolving
    let dspEngine: DSPEngine
    let demoPlaybackService: DemoPlaybackService
    let playbackMetadataService: PlaybackMetadataService
    let permissionsService: PermissionsService
    let launchAtLoginService: LaunchAtLoginService
    let presetStore: PresetStore
    let settingsStore: SettingsStore
    let outputDeviceObserver: OutputDeviceObserving
    
    static func makeDefault() -> AppEnvironment {
        let settingsStore = InMemorySettingsStore()
        let presetStore = InMemoryPresetStore()
        let livePipeline = LiveAudioPipelineBridge()

        return AppEnvironment(
            audioCaptureService: LiveAudioCaptureService(pipeline: livePipeline),
            audioSourceResolver: DefaultAudioSourceResolver(),
            dspEngine: LiveDSPEngine(pipeline: livePipeline),
            demoPlaybackService: SystemDemoPlaybackService(),
            playbackMetadataService: StubPlaybackMetadataService(),
            permissionsService: SystemAudioPermissionsService(),
            launchAtLoginService: StubLaunchAtLoginService(),
            presetStore: presetStore,
            settingsStore: settingsStore,
            outputDeviceObserver: StubOutputDeviceObserver()
            
        )
    }
}
