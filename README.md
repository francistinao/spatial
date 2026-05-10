# SP8IAL (Spatial)

> Real-time 8D audio processing utility for macOS

---

## Overview

Sp8ial is a macOS utility application that intercepts your system audio in real-time and applies an 8D spatial audio effect — HRTF panning, LFO rotation, reverb, and stereo width expansion. It works transparently over any audio source: Spotify, Apple Music, YouTube, or any browser-based player.

**Positioning:** Fun, focused, not scalable by design — a single-purchase utility. One-time purchase, no subscription, no backend.

**Price:** To be discussed
**Distribution:** Direct `.dmg` download, outside the Mac App Store  
**Platform:** macOS 14 (Sonoma) and later  
**Architecture:** Native Swift — Intel + Apple Silicon universal binary

---

## How It Works

### The core insight — DRM is not a problem

Spatial never touches protected audio files. By the time the app sees audio, DRM has already been decoded by the source app (Spotify, Apple Music, etc.) internally. What Spatial intercepts is the decoded **raw PCM audio stream** headed to your speakers — the same approach used by eqMac, Boom 3D, and other legitimate Mac audio enhancers.

### Audio pipeline

```
Spotify / Apple Music / Browser
        ↓
   App decodes DRM internally
   (raw PCM exits the app process)
        ↓
   Core Audio Tap
   (intercepts decoded PCM stream)
   macOS 14+ native API — no custom driver needed
        ↓
   8D DSP Engine (AVAudioEngine)
   ├── HRTF panning     — binaural 3D positioning
   ├── LFO rotation     — auto-pan sweep (speed-controlled)
   ├── Reverb           — room/space simulation
   └── Stereo width     — soundstage expansion
        ↓
   Output → Headphones / Speakers
```

---

## Technical Discussion

### Audio Capture

- **Primary path:** `Spatial Speaker` HAL driver
- **Secondary / debug path:** `AVAudioEngine` + Core Audio tap / ScreenCapture-style fallback where available
- **Aggregate device pattern:** Core Audio tap → aggregate device → IO proc callback → DSP thread
- **Latency target:** Sub-10ms end-to-end (128-frame buffer)
- **Thread model:** Minimal work in the audio callback; push PCM chunks to a processing thread via lock-free ring buffer

### 8D DSP Engine

All processing via `AVAudioEngine` node graph:

| Stage        | Implementation                       | Notes                                     |
| ------------ | ------------------------------------ | ----------------------------------------- |
| HRTF panning | `AVAudioEnvironmentNode`             | Apple's built-in binaural renderer        |
| LFO rotation | Custom `AVAudioUnit`                 | Sine-wave oscillator driving pan position |
| Reverb       | `AVAudioUnitReverb`                  | `AVAudioUnitReverbPreset` + wet/dry mix   |
| Stereo width | Custom `AVAudioUnit` mid-side matrix | M/S encode → scale side channel → decode  |

**LFO rotation math:**

```
panPosition(t) = sin(2π × speed × t) × rotationAmount
elevationAngle = elevation × (π/2)
```

### macOS Integration

- **Menu bar:** `NSStatusItem` + `NSPopover` for the dropdown widget
- **Permissions:** Accessibility access via `AXIsProcessTrusted()` — no Input Monitoring needed (audio tap is separate from key logging)
- **Launch at login:** `SMAppService.mainApp.register()` (macOS 13+ modern API, no LaunchAgents plist)
- **Driver install path:** `/Library/Audio/Plug-Ins/HAL/SpatialSpeaker.driver`
- **Code signing:** real Apple signing identity required for development; stable release signing required for shipped builds

### Privacy Architecture

- Fully offline — zero network requests after download
- No keystroke logging — audio tap only captures decoded PCM, not typed text
- No analytics, no telemetry, no crash reporting (by design — keeps the binary clean)
- Audio never written to disk during processing

---

## Known Constraints & Edge Cases

- **macOS 14+ only** — Core Audio tap API (`CATapDescription`) is not available on earlier versions. Show upgrade prompt on 13 and below.
- **Headphones strongly recommended** — 8D/HRTF effect is designed for stereo headphones. Works on speakers but the spatial illusion is significantly reduced. Show a one-time tooltip.
- **Bluetooth latency** — cannot compensate for Bluetooth codec latency. Recommend wired or AirPods (AAC low-latency mode).
- **Driver trust is critical** — the HAL bundle may be present on disk but still unusable if macOS rejects its signature.
- **Apple Silicon vs Intel** — `AVAudioEngine` and `vDSP` are both fully optimized for Apple Silicon. Universal binary required for Intel compatibility.
- **Multiple audio outputs** — tap captures the default system output device only. If user switches output mid-session, re-initialize the tap.

_Built with AVAudioEngine + SwiftUI + Core Audio. Distributed outside the App Store as a notarized .dmg._ 

Built with <3 by Francis Tin-ao
