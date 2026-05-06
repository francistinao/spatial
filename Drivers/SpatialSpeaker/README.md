# Spatial Speaker Driver

This folder contains the first-party `Spatial Speaker` virtual audio driver.

Development install path:

1. Build the `SpatialSpeaker` target with a real Apple signing identity.
2. Install the produced `.driver` bundle into `/Library/Audio/Plug-Ins/HAL/`.
3. Restart `coreaudiod` or reboot the Mac.
4. Launch Spatial and confirm that `Spatial Speaker` appears in Audio MIDI Setup.

Signing notes:

- The HAL bundle should not be installed ad-hoc signed on this setup; macOS may reject it before Core Audio can publish the device.
- The `SpatialSpeaker` target now accepts explicit build settings:
  `SPATIAL_DEVELOPMENT_TEAM`
  `SPATIAL_CODESIGN_IDENTITY`
  `SPATIAL_OTHER_CODE_SIGN_FLAGS`
- Example build:
  `xcodebuild -project Spatial.xcodeproj -scheme SpatialSpeaker -configuration Debug -derivedDataPath .build-derived SPATIAL_DEVELOPMENT_TEAM=YOURTEAMID SPATIAL_CODESIGN_IDENTITY="Apple Development" build`
- Example install:
  `SPATIAL_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Drivers/SpatialSpeaker/install.sh`

Current state:

- The app-side routing, monitor-device pinning, and device-backed capture path are wired for `Spatial Speaker`.
- The driver publishes a minimal Core Audio AudioServerPlugIn device with stereo input/output streams so Spatial can route output into the virtual speaker and capture the looped-back signal.
- The remaining work is hardening the driver behavior under real macOS load, installation edge cases, and long-running IO.
