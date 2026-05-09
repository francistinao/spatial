# Spatial Speaker Driver

This folder contains the first-party `Spatial Speaker` virtual audio driver. `Spatial Speaker` is the supported system-audio path for the app. The ScreenCaptureKit fallback remains debug-only because it can produce dangerously distorted output on some Macs.

## Supported Flow

1. Confirm that this Mac has a real Apple code-signing identity:
   `Drivers/SpatialSpeaker/preflight-signing.sh`
2. Build the `SpatialSpeaker` target with a real Apple Development identity:
   `xcodebuild -project Spatial.xcodeproj -scheme SpatialSpeaker -configuration Debug -derivedDataPath .build-derived SPATIAL_DEVELOPMENT_TEAM=YOURTEAMID SPATIAL_CODESIGN_IDENTITY="Apple Development" build`
3. Install the produced `.driver` bundle into `/Library/Audio/Plug-Ins/HAL/`:
   `SPATIAL_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Drivers/SpatialSpeaker/install.sh`
4. Restart `coreaudiod` or reboot the Mac.
5. Launch Spatial and confirm that `Spatial Speaker` appears in Audio MIDI Setup and in `system_profiler SPAudioDataType`.

## Signing Notes

- The HAL bundle should not be installed ad-hoc signed on this setup; macOS may reject it before Core Audio can publish the device.
- The `SpatialSpeaker` target accepts these explicit build settings:
  `SPATIAL_DEVELOPMENT_TEAM`
  `SPATIAL_CODESIGN_IDENTITY`
  `SPATIAL_OTHER_CODE_SIGN_FLAGS`
- `Drivers/SpatialSpeaker/install.sh` fails fast on ad-hoc signed HAL bundles unless `SPATIAL_ALLOW_ADHOC_DRIVER=1` is set explicitly for debugging.

## Diagnostics

Run the repo-supported diagnostics workflow with:

`Drivers/SpatialSpeaker/diagnose.sh`

It captures:

- available code-signing identities
- installed driver signature details
- build-vs-installed executable hash parity
- filtered `coreaudiod` and `amfid` logs
- `system_profiler SPAudioDataType`

### Live capture investigation

When debugging the "HAL callbacks fire but every peak is 0.0000" failure, two extra
helpers are available:

`Drivers/SpatialSpeaker/debug-capture-logs.sh [seconds]`

Streams three independent log predicates (driver subsystem, coreaudiod/AUHAL,
Spatial app subsystem) into a timestamped `debug-logs/` folder while you perform
exactly one capture attempt. Prints a count summary at the end (AddDeviceClient,
StartIO, WillDoIOOperation, DoIO, ReadInput, WriteMix, -10877, IOWorkLoop overload).
The summary auto-classifies the failure mode (e.g. "received AddDeviceClient but
NEVER received StartIO").

`swift Drivers/SpatialSpeaker/blackhole-ab-test.swift <deviceUIDOrName> [seconds]`

Stand-alone Swift CLI that mirrors `LiveAudioCaptureService.startLoopbackCaptureWithHALInputUnit`'s
exact property-set sequence with per-call status logging. Use it to A/B test the
same setup against any installed virtual loopback (BlackHole 2ch, Loopback, etc.)
to determine whether the bug is in our driver's property model or in the Swift
AUHAL setup. Examples:

```
swift Drivers/SpatialSpeaker/blackhole-ab-test.swift "BlackHole 2ch" 5
swift Drivers/SpatialSpeaker/blackhole-ab-test.swift com.spatial.app.driver.speaker 5
```

## Failure Signatures

- `amfid ... adhoc signed or signed by an unknown certificate chain`
  The HAL bundle is not trusted on this Mac. Rebuild and reinstall with a real Apple Development identity.
- `Spatial Speaker readiness failed: device not found`
  The bundle may be installed, but macOS has not published a usable Core Audio device for it yet. Check signing, factory UUID conflicts, and the diagnostics script output.
- `HALS_PlugIn::HostInterface_PropertiesChanged: the object is not valid`
  Core Audio is rejecting part of the driver object graph during publication. Audit `SpatialSpeakerDriver.c` property size/data consistency first.
- `AddInstanceForFactory ... F8BB1C28-BAE8-11D6-9C31-00039315CD46`
  Core Audio is probing the legacy AudioServerPlugIn factory path. `Info.plist` and `SpatialSpeaker_Create` must continue to support that UUID.
- Severe distortion / “earrape” while peaks look healthy in logs
  Core Audio may attach **multiple capture clients** to the same device. A single consumer ring makes each `ReadInput` eat a disjoint slice of the writer’s frames. From `diag-2026-05-09-r10-peekread` onward, `ReadInput` **peeks** the newest samples (same mix for every tap) instead of partitioning the ring across readers.

## Current State

- The app-side routing, monitor-device pinning, and device-backed capture path are wired for `Spatial Speaker`.
- The driver publishes a minimal Core Audio AudioServerPlugIn device with stereo input/output streams so Spatial can route output into the virtual speaker and capture the looped-back signal.
- The remaining work is validating the hardened object graph under real signed-driver load and confirming publication on a Mac with a trusted signing identity.
