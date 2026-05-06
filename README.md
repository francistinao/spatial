# Spatial — Technical README

> Real-time 8D audio processing utility for macOS

---

## Overview

Spatial is a macOS utility application that intercepts your system audio in real-time and applies an 8D spatial audio effect — HRTF panning, LFO rotation, reverb, and stereo width expansion. It works transparently over any audio source: Spotify, Apple Music, YouTube, or any browser-based player.

**Positioning:** Fun, focused, not scalable by design — a single-purchase utility in the spirit of Keeby ($4.99 mech keyboard sounds for Mac). One-time purchase, no subscription, no backend.

**Price:** $5.99 one-time  
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

## Technical Stack

### Audio Capture

- **API:** `AVAudioEngine` + Core Audio tap (macOS 14+, `CATapDescription`)
- **No custom kernel extension or virtual audio driver required** — this is the key differentiator from older approaches (eqMac requires a custom driver; Spatial does not)
- **Aggregate device pattern:** Core Audio tap → aggregate device → IO proc callback → DSP thread
- **Latency target:** Sub-10ms end-to-end (128-frame buffer, same as Keeby's approach)
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
- **App Sandbox:** Disabled — required for system audio tap access. This is why distribution is outside the App Store.
- **Code signing:** Developer ID Application certificate required for Gatekeeper notarization

### Privacy Architecture

- Fully offline — zero network requests after download
- No keystroke logging — audio tap only captures decoded PCM, not typed text
- No analytics, no telemetry, no crash reporting (by design — keeps the binary clean)
- Audio never written to disk during processing

---

## UI Architecture

### Widget (Main Popover)

**Dimensions:** 320px wide × ~560px tall  
**Component:** `NSPopover` attached to `NSStatusItem`, `NSViewController` with SwiftUI content

**Sections:**

1. Header — app name + power toggle (`NSStatusItem` icon reflects state)
2. Visualizer — 32-bar spectrum display, `CALayer`-based, updates at 30fps, pan position animated
3. Now Playing — reads from `MusicKit` (Apple Music) or `NowPlayableExtension` / Spotify `AppleScript` bridge
4. 8D Controls — 4 rotary knobs (custom `NSControl` subclass), drag-to-adjust
5. Speed + Elevation sliders — `NSSlider` styled
6. Presets — 4 preset configurations stored in `UserDefaults`
7. Settings gear → secondary popover (Screen 4)

### Knob Control

Custom `NSControl` subclass:

- Mouse-down → track vertical delta → map to 0–100% value
- Draw: `CAShapeLayer` arc (270° sweep), filled arc overlay, endpoint dot
- Accessibility: `NSAccessibilitySlider` role, value announcements

### Visualizer

- `AVAudioEngine` tap on output node → FFT via `vDSP_DFT_zrop` → 32-bin magnitude array
- `CADisplayLink`-equivalent (`CVDisplayLink`) drives render at display refresh rate
- Bar heights lerp toward target: `current += (target - current) × 0.18` per frame
- Pan position dot overlaid: `x = sin(lfoPhase) × 0.5 + 0.5` mapped to bar index

---

## Preset Configurations

| Preset  | Rotation | Depth | Reverb | Width | Speed | Elevation |
| ------- | -------- | ----- | ------ | ----- | ----- | --------- |
| Subtle  | 40%      | 25%   | 15%    | 60%   | 3     | 40%       |
| Classic | 60%      | 45%   | 30%    | 80%   | 4     | 55%       |
| Deep    | 80%      | 70%   | 60%    | 90%   | 2     | 70%       |
| Concert | 90%      | 80%   | 75%    | 100%  | 5     | 85%       |

---

## Source Compatibility

| Source                  | Works? | Notes                                                     |
| ----------------------- | ------ | --------------------------------------------------------- |
| Spotify (desktop)       | ✅     | PCM decoded before Core Audio tap                         |
| Apple Music             | ✅     | FairPlay decoded internally by app                        |
| YouTube (Safari/Chrome) | ✅     | Browser audio through system output                       |
| SoundCloud, Tidal, etc. | ✅     | Any app that outputs to system audio                      |
| Bluetooth audio         | ⚠️     | Works but BT stack adds ~80–200ms latency of its own      |
| AirPlay output          | ⚠️     | Tap may not intercept AirPlay stream depending on routing |

---

## Distribution & Monetization

- **License:** One-time purchase, lifetime updates
- **Payment:** LemonSqueezy or Paddle (both support direct download + license key)
- **Delivery:** License key activates app via local validation (no server ping after activation)
- **Trial:** 3-day free trial — full functionality, banner shown in widget
- **DMG layout:** Standard macOS drag-to-Applications installer
- **Updates:** Sparkle framework for in-app update checks

---

## Design System

### Colors

| Token           | Hex                      | Usage                            |
| --------------- | ------------------------ | -------------------------------- |
| Base background | `#0D0D0D`                | App background                   |
| Card surface    | `#1A1A1A`                | Widget, popovers                 |
| Border          | `rgba(255,255,255,0.07)` | All card borders                 |
| Primary accent  | `#7F5AF0`                | 8D controls, active states       |
| Accent light    | `#A78BFA`                | Active text, dot indicator       |
| Active green    | `#2CB67D`                | Power on, launch at login toggle |
| Text primary    | `#FFFFFE`                | Values, headings                 |
| Text secondary  | `#94A1B2`                | Labels, artist name              |
| Text tertiary   | `#72757E`                | Section headers, metadata        |

### Typography

| Role                       | Font           | Size    | Weight       |
| -------------------------- | -------------- | ------- | ------------ |
| Section labels             | SF Pro Rounded | 11px    | 500 Medium   |
| Badge / pill text          | SF Pro Rounded | 10–11px | 500 Medium   |
| Slider / settings labels   | SF Pro Text    | 12px    | 400 Regular  |
| Card titles, track name    | SF Pro Text    | 13px    | 600 Semibold |
| Onboarding body            | SF Pro Text    | 14px    | 400 Regular  |
| Knob values, slider values | SF Pro Display | 11–16px | 700 Bold     |
| Onboarding headline        | SF Pro Display | 22px    | 600 Semibold |
| Large numeric readouts     | SF Pro Display | 28px+   | 700 Bold     |
| Shortcut badges, version   | SF Mono        | 11–12px | 400 Regular  |

**Rules:**

- SF Pro Display for all numbers and headings (17px+)
- SF Pro Text for all labels and functional body copy (≤16px)
- SF Pro Rounded for badges, pills, preset buttons
- SF Mono strictly for shortcut key badges and version strings
- Uppercase section labels: `letter-spacing: 0.07em`
- Large numerics: `letter-spacing: -0.02em`

### Logo

Icon anatomy:

- **Figure-8 path** — two lobes pinched at center, references "8D"
- **Tilted orbital ellipse** — ~20° rotation, represents 3D/spatial dimension
- **Accent dot** — travels along orbit when active (menu bar animation)
- Icon background: `#1A1A1A` circle pill for all sizes except menu bar (transparent)

Wordmark: `SPATIAL` in SF Pro Display Bold, `letter-spacing: 0.08em`  
Tagline: `8D AUDIO ENGINE` in SF Pro Text Medium, `letter-spacing: 0.18em`, color `#7F5AF0`

---

## Screens

| Screen           | Description                                                              |
| ---------------- | ------------------------------------------------------------------------ |
| Menu bar icon    | 3 states: Active (violet), Bypassed (gray), Processing (orbit animation) |
| Main widget      | Dropdown popover — visualizer, now playing, knobs, sliders, presets      |
| Onboarding       | First-launch permission request — privacy-first messaging                |
| Settings popover | Audio source, rotation pattern, hotkey, launch at login                  |

---

## Known Constraints & Edge Cases

- **macOS 14+ only** — Core Audio tap API (`CATapDescription`) is not available on earlier versions. Show upgrade prompt on 13 and below.
- **Headphones strongly recommended** — 8D/HRTF effect is designed for stereo headphones. Works on speakers but the spatial illusion is significantly reduced. Show a one-time tooltip.
- **Bluetooth latency** — cannot compensate for Bluetooth codec latency. Recommend wired or AirPods (AAC low-latency mode).
- **App Sandbox disabled** — means App Store distribution is not possible. Gatekeeper notarization via `xcrun notarytool` is still required.
- **Apple Silicon vs Intel** — `AVAudioEngine` and `vDSP` are both fully optimized for Apple Silicon. Universal binary required for Intel compatibility.
- **Multiple audio outputs** — tap captures the default system output device only. If user switches output mid-session, re-initialize the tap.

---

## Roadmap (Post-Launch)

- [ ] v1.0 — Core 8D engine, widget UI, 4 presets
- [ ] v1.1 — Per-app audio source selector (process-specific tap)
- [ ] v1.2 — Custom preset save/load
- [ ] v1.3 — Hotkey to toggle effect on/off globally
- [ ] v2.0 — Additional effect modes (concert hall, stadium, vinyl warmth)

---

_Built with AVAudioEngine + SwiftUI + Core Audio. Distributed outside the App Store as a notarized .dmg._
