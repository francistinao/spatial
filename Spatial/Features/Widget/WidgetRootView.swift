import AppKit
import SwiftUI

struct WidgetRootView: View {
    @ObservedObject var model: SpatialAppModel
    let openSettings: () -> Void

    private var layout: SpatialMetrics.WidgetLayoutProfile {
        SpatialMetrics.widgetLayout(for: NSScreen.main?.visibleFrame.height ?? SpatialMetrics.widgetExpandedHeight)
    }

    private var themeAccent: Color {
        Color(hex: model.settings.theme.accentHex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchBar
                .padding(.top, layout.notchTopPadding)

            if model.widgetDisplayMode == .expanded {
                ExpandedWidgetView(model: model, openSettings: openSettings, layout: layout, themeAccent: themeAccent)
                    .padding(.top, expandedWidgetTopPadding)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(
            width: model.widgetDisplayMode == .expanded ? layout.width : SpatialMetrics.popoverWidth,
            height: model.widgetDisplayMode == .expanded ? layout.expandedHeight : SpatialMetrics.widgetCollapsedHeight,
            alignment: .top
        )
    }

    private var expandedWidgetTopPadding: CGFloat {
        layout.notchTopPadding + layout.notchHeight + layout.notchCardGap
    }

    private var notchBar: some View {
        CollapsedWidgetView(model: model, themeAccent: themeAccent)
            .padding(.bottom, 16)
            .onTapGesture {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    if model.widgetDisplayMode == .expanded {
                        model.collapseWidgetIfPossible()
                    } else {
                        model.expandWidget()
                    }
                }
            }
    }
}

private struct ExpandedWidgetView: View {
    @ObservedObject var model: SpatialAppModel
    let openSettings: () -> Void
    let layout: SpatialMetrics.WidgetLayoutProfile
    let themeAccent: Color

    var body: some View {
        VStack(spacing: 0) {
            header
            positionVisualizer
            nowPlayingCard
            controls
            sliders
            presets
            footer
        }
        .padding(.top, layout.mode == .compact ? 2 : 4)
        .background(widgetBackground)
        .clipShape(RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: layout.cardCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 24, y: 16)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image("logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: layout.headerLogoHeight)

            Spacer()

            Button(action: model.togglePower) {
                ZStack {
                    Circle()
                        .fill(Color(hex: 0x271E3F))
                        .frame(width: layout.headerControlSize, height: layout.headerControlSize)

                    Circle()
                        .stroke(SpatialColor.accent.opacity(0.42), lineWidth: 1)
                        .frame(width: layout.headerControlSize, height: layout.headerControlSize)

                    Image(systemName: model.state.isEnabled ? "waveform.path.ecg" : "power")
                        .font(SpatialTypography.header(max(11, layout.sectionTitleFontSize + 2)))
                        .foregroundStyle(model.state.isEnabled ? SpatialColor.accentLight : SpatialColor.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, layout.headerHorizontalPadding)
        .padding(.top, layout.mode == .compact ? max(4, layout.headerTopPadding - 4) : max(6, layout.headerTopPadding - 4))
        .padding(.bottom, layout.headerBottomPadding)
    }

    private var positionVisualizer: some View {
        VStack(spacing: layout.visualizerSubtitleSpacing + 6) {
            VisualizerPanel(bars: model.visualizerBars, layout: layout, themeAccent: themeAccent)
                .frame(height: layout.visualizerHeight)

            VStack(spacing: layout.visualizerSubtitleSpacing) {
                Text("8D POSITION")
                    .font(SpatialTypography.header(layout.visualizerTitleFontSize))
                    .tracking(layout.sectionTitleTracking)
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.82))

                Text(positionVisualizerSubtitle)
                    .font(SpatialTypography.text(layout.visualizerSubtitleFontSize))
                    .lineSpacing(layout.helperTextLineSpacing)
                    .foregroundStyle(SpatialColor.textSecondary.opacity(0.9))
            }
        }
        .padding(.horizontal, layout.sectionHorizontalPadding)
        .padding(.bottom, layout.visualizerBottomPadding)
    }

    private var nowPlayingCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0x343434), Color(hex: 0x191919)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                ArtworkThumbnailView(
                    artworkURL: model.displayArtworkURL,
                    fallbackSystemName: model.displayArtworkSystemName
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(width: layout.nowPlayingArtworkSize, height: layout.nowPlayingArtworkSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.collapsedTitle)
                    .font(SpatialTypography.header(layout.nowPlayingTitleFontSize))
                    .foregroundStyle(SpatialColor.textPrimary)
                    .lineLimit(1)

                Text(model.displayArtistName)
                    .font(SpatialTypography.text(layout.nowPlayingSubtitleFontSize))
                    .foregroundStyle(SpatialColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            SourceBadge(source: model.selectedAudioSource, layout: layout)
        }
        .padding(.horizontal, layout.nowPlayingHorizontalPadding)
        .padding(.vertical, layout.nowPlayingVerticalPadding)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, layout.sectionHorizontalPadding)
        .padding(.bottom, layout.nowPlayingBottomPadding)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("8D CONTROLS")
                .font(SpatialTypography.header(layout.sectionTitleFontSize))
                .tracking(layout.sectionTitleTracking)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.84))

            HStack(spacing: layout.controlsSpacing) {
                MixerRotaryKnob(title: "ROTATION", value: binding(for: \.rotation), displayText: "\(Int(model.settings.rotation * 100))%", layout: layout)
                MixerRotaryKnob(title: "DEPTH", value: binding(for: \.depth), displayText: "\(Int(model.settings.depth * 100))%", layout: layout)
                MixerRotaryKnob(title: "REVERB", value: binding(for: \.reverb), displayText: "\(Int(model.settings.reverb * 100))%", layout: layout)
                MixerRotaryKnob(title: "WIDTH", value: binding(for: \.width), displayText: "\(Int(model.settings.width * 100))%", layout: layout)
            }

            Text("Rotation sets orbit span. Depth shapes binaural intensity. Reverb adds space. Width expands the stereo image.")
                .font(SpatialTypography.text(layout.helperTextFontSize))
                .lineSpacing(layout.helperTextLineSpacing)
                .foregroundStyle(SpatialColor.textSecondary.opacity(0.9))

            if !model.areLiveControlsEnabled,
               model.liveControlsStatusText != positionVisualizerSubtitle {
                Text(model.liveControlsStatusText)
                    .font(SpatialTypography.header(layout.helperTextFontSize))
                    .foregroundStyle(SpatialColor.accentLight.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, layout.sectionHorizontalPadding)
        .padding(.bottom, layout.controlsBottomPadding)
        .disabled(!model.areLiveControlsEnabled)
        .opacity(model.areLiveControlsEnabled ? 1 : 0.6)
    }

    private var sliders: some View {
        VStack(spacing: layout.slidersVerticalSpacing) {
            HStack(alignment: .top, spacing: layout.sliderRowSpacing) {
                Spacer(minLength: 0)

                MixerVerticalFader(
                    title: "SPEED",
                    value: Binding(
                        get: { max(0, min(1, (model.settings.speed - 1.0) / 9.0)) },
                        set: { model.updateSpeed(max(1, min(10, ($0 * 9.0) + 1.0)).rounded()) }
                    ),
                    displayText: "\(Int(model.settings.speed))",
                    layout: layout
                )

                MixerVerticalFader(
                    title: "ELEVATION",
                    value: binding(for: \.elevation),
                    displayText: "\(Int(model.settings.elevation * 100))%",
                    layout: layout
                )

                MixerVerticalFader(
                    title: "CENTER FOCUS",
                    value: binding(for: \.centerFocus),
                    displayText: "\(Int(model.settings.centerFocus * 100))%",
                    layout: layout
                )

                MixerVerticalFader(
                    title: "MOTION CURVE",
                    value: binding(for: \.motionCurve),
                    displayText: "\(Int(model.settings.motionCurve * 100))%",
                    layout: layout
                )

                Spacer(minLength: 0)
            }

            Text("Speed sets orbit pace. Elevation lifts the path above and below ear level. Center Focus anchors the phantom center. Motion Curve shifts the orbit from smooth to aggressive.")
                .font(SpatialTypography.text(layout.helperTextFontSize))
                .lineSpacing(layout.helperTextLineSpacing)
                .foregroundStyle(SpatialColor.textSecondary.opacity(0.9))
        }
        .padding(.horizontal, layout.sectionHorizontalPadding)
        .padding(.bottom, layout.slidersBottomPadding)
        .disabled(!model.areLiveControlsEnabled)
        .opacity(model.areLiveControlsEnabled ? 1 : 0.6)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: layout.presetsSpacing) {
            Text("PRESETS")
                .font(SpatialTypography.header(layout.sectionTitleFontSize))
                .tracking(layout.sectionTitleTracking - 0.2)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.82))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.presetGridMinimum), spacing: layout.presetGridSpacing)], spacing: layout.presetGridSpacing) {
                ForEach(model.presets) { preset in
                    Button(action: { model.selectPreset(preset.kind) }) {
                        Text(preset.kind.displayName)
                            .font(SpatialTypography.header(layout.presetFontSize))
                            .tracking(0.8)
                            .foregroundStyle(SpatialColor.textPrimary.opacity(model.selectedPreset == preset.kind ? 1 : 0.88))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, layout.presetVerticalPadding)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        model.selectedPreset == preset.kind
                                            ? SpatialColor.accent.opacity(0.24)
                                            : Color.white.opacity(0.06)
                                    )
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(model.selectedPreset == preset.kind ? SpatialColor.accent.opacity(0.95) : Color.white.opacity(0.07), lineWidth: 1)
                            )
                            .shadow(color: model.selectedPreset == preset.kind ? SpatialColor.accent.opacity(0.24) : .clear, radius: 14, y: 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, layout.sectionHorizontalPadding)
        .padding(.bottom, layout.presetsBottomPadding)
        .disabled(!model.areLiveControlsEnabled)
        .opacity(model.areLiveControlsEnabled ? 1 : 0.6)
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(SpatialTypography.text(14))
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.9))
                    .frame(width: layout.footerIconWidth)
            }
            .buttonStyle(.plain)

            Button(action: model.collapseWidgetIfPossible) {
                Image(systemName: "chevron.up")
                    .font(SpatialTypography.text(14))
                    .foregroundStyle(SpatialColor.textSecondary)
                    .frame(width: layout.footerIconWidth)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.engineStatusText.uppercased())
                    .font(SpatialTypography.header(layout.footerPrimaryFontSize))
                    .tracking(layout.footerPrimaryTracking)
                    .foregroundStyle(SpatialColor.accentLight)

                Text(model.spatialTuningSummary)
                    .font(SpatialTypography.text(layout.footerSecondaryFontSize))
                    .foregroundStyle(SpatialColor.textSecondary)
            }
        }
        .padding(.horizontal, layout.footerHorizontalPadding)
        .padding(.vertical, layout.footerVerticalPadding)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var widgetBackground: some View {
        LinearGradient(
            colors: [Color(hex: 0x1D1D1D), Color(hex: 0x171717), Color(hex: 0x131313)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var positionVisualizerSubtitle: String {
        if model.isDemoModeActive {
            return "Visualizer synced to demo signal level"
        }

        if !model.areLiveControlsEnabled {
            return model.liveControlsStatusText
        }

        if model.hasDryWetEchoRisk {
            return model.echoRiskMessage
        }

        if model.environment.dspEngine.supportsLiveInputProcessing {
            return "Live orbit motion follows captured audio in real time."
        }

        return "Preview animation only. Live capture DSP is not wired in this build."
    }

    private func binding(for keyPath: WritableKeyPath<SpatialSettings, Double>) -> Binding<Double> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                switch keyPath {
                case \.rotation:
                    model.updateRotation(value)
                case \.depth:
                    model.updateDepth(value)
                case \.reverb:
                    model.updateReverb(value)
                case \.width:
                    model.updateWidth(value)
                case \.elevation:
                    model.updateElevation(value)
                case \.centerFocus:
                    model.updateCenterFocus(value)
                case \.motionCurve:
                    model.updateMotionCurve(value)
                default:
                    break
                }
            }
        )
    }
}

private struct CollapsedWidgetView: View {
    @ObservedObject var model: SpatialAppModel
    let themeAccent: Color

    var body: some View {
        HStack(spacing: 12) {
            CompactVisualizerGlyph(bars: Array(model.visualizerBars.prefix(4)), themeAccent: themeAccent)

            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))

                    ArtworkThumbnailView(
                        artworkURL: model.displayArtworkURL,
                        fallbackSystemName: model.displayArtworkSystemName
                    )
                    .font(SpatialTypography.text(11))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(model.collapsedTitle)
                        .font(SpatialTypography.text(14))
                        .foregroundStyle(SpatialColor.textPrimary)
                        .lineLimit(1)

                    Text(model.collapsedSubtitle)
                        .font(SpatialTypography.header(10))
                        .tracking(0.9)
                        .foregroundStyle(SpatialColor.textSecondary.opacity(0.94))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            CompactVisualizerGlyph(bars: Array(model.visualizerBars.suffix(4)), themeAccent: themeAccent)
        }
        .padding(.horizontal, 18)
        .frame(width: SpatialMetrics.popoverWidth - 36, height: 36)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.26), radius: 14, y: 6)
        .contentShape(Capsule())
    }
}

private struct VisualizerPanel: View {
    let bars: [CGFloat]
    let layout: SpatialMetrics.WidgetLayoutProfile
    let themeAccent: Color

    var body: some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: layout.mode == .compact ? 3 : 4) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                    Capsule(style: .continuous)
                        .fill(themeAccent)
                        .frame(width: layout.mode == .compact ? 4 : 5, height: max(layout.mode == .compact ? 10 : 12, value * (layout.mode == .compact ? 72 : 84)))
                }
            }
            .padding(.horizontal, layout.sectionHorizontalPadding)
            .padding(.bottom, layout.mode == .compact ? 8 : 10)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.04), lineWidth: 1)
        )
    }
}

private struct CompactVisualizerGlyph: View {
    let bars: [CGFloat]
    let themeAccent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                Rectangle()
                    .fill(themeAccent)
                    .frame(width: 3.5, height: max(9, value * 18))
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

private struct SourceBadge: View {
    let source: AudioSourceOption?
    let layout: SpatialMetrics.WidgetLayoutProfile

    var body: some View {
        Text(source?.title.replacingOccurrences(of: "\n", with: " ") ?? "None")
            .font(SpatialTypography.header(layout.badgeFontSize))
            .tracking(0.2)
            .foregroundStyle(source?.statusTint ?? SpatialColor.textTertiary)
            .padding(.horizontal, layout.badgeHorizontalPadding)
            .padding(.vertical, layout.badgeVerticalPadding)
            .background(
                Capsule(style: .continuous)
                    .fill((source?.statusTint ?? SpatialColor.accent).opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke((source?.statusTint ?? SpatialColor.accent).opacity(0.25), lineWidth: 1)
            )
    }
}

private struct ArtworkThumbnailView: View {
    let artworkURL: URL?
    let fallbackSystemName: String

    var body: some View {
        Group {
            if let artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty, .failure:
                        fallbackArtwork
                    @unknown default:
                        fallbackArtwork
                    }
                }
            } else {
                fallbackArtwork
            }
        }
    }

    private var fallbackArtwork: some View {
        Image(systemName: fallbackSystemName)
            .font(SpatialTypography.text(20))
            .foregroundStyle(SpatialColor.accentLight.opacity(0.85))
    }
}

private struct MixerRotaryKnob: View {
    let title: String
    @Binding var value: Double
    let displayText: String
    let layout: SpatialMetrics.WidgetLayoutProfile
    @State private var dragStartValue: Double?
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: layout.knobStackSpacing) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: layout.knobOuterSize, height: layout.knobOuterSize)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: 0x2A2A2F), Color(hex: 0x1A1A1F)],
                            center: .topLeading,
                            startRadius: 3,
                            endRadius: 30
                        )
                    )
                    .frame(width: layout.knobPrimaryRingSize, height: layout.knobPrimaryRingSize)

                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    .frame(width: layout.knobPrimaryRingSize, height: layout.knobPrimaryRingSize)

                Circle()
                    .stroke(Color.black.opacity(0.6), lineWidth: 4)
                    .frame(width: layout.knobDarkRingSize, height: layout.knobDarkRingSize)

                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
                    .frame(width: layout.knobInnerRingSize, height: layout.knobInnerRingSize)

                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(SpatialColor.accentLight)
                    .frame(width: layout.knobIndicatorWidth, height: layout.knobIndicatorHeight)
                    .offset(y: -layout.knobIndicatorOffsetY)
                    .rotationEffect(indicatorAngle)
                    .shadow(color: SpatialColor.accent.opacity(0.20), radius: 4, y: 1)
            }
            .scaleEffect(isHovering ? 1.02 : 1)
            .contentShape(Circle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.18)) {
                    isHovering = hovering
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let delta = Double(-gesture.translation.height / 130)
                        value = min(1, max(0, start + delta))
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )

            Text(displayText)
                .font(SpatialTypography.header(layout.knobValueFontSize))
                .foregroundStyle(SpatialColor.accentLight.opacity(0.95))

            Text(title)
                .font(SpatialTypography.header(layout.knobTitleFontSize))
                .tracking(0.9)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.9))
        }
        .frame(maxWidth: .infinity)
    }

    private var indicatorAngle: Angle {
        let minAngle = -140.0
        let maxAngle = 140.0
        return .degrees(minAngle + ((maxAngle - minAngle) * value))
    }
}

private struct MixerVerticalFader: View {
    let title: String
    @Binding var value: Double
    let displayText: String
    let layout: SpatialMetrics.WidgetLayoutProfile
    @State private var dragStartValue: Double?
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: layout.faderStackSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.52), Color.black.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: layout.faderTrackWidth, height: layout.faderTrackHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )

                HStack(spacing: layout.mode == .compact ? 6 : 8) {
                    faderRail
                    faderRail
                }
                .frame(height: layout.faderTrackHeight - 18)

                VStack {
                    ForEach(0..<5, id: \.self) { _ in
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 8, height: 1.2)
                        Spacer()
                    }
                }
                .padding(.vertical, 12)

                faderCap
                    .offset(y: capOffset)
            }
            .contentShape(Rectangle())
            .scaleEffect(isHovering ? 1.02 : 1)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.18)) {
                    isHovering = hovering
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil {
                            dragStartValue = value
                        }
                        let delta = Double(-gesture.translation.height / usableTravelHeight)
                        value = min(1, max(0, start + delta))
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                    }
            )

            Text(displayText)
                .font(SpatialTypography.header(layout.faderValueFontSize))
                .foregroundStyle(SpatialColor.accentLight.opacity(0.96))

            Text(title)
                .font(SpatialTypography.header(layout.faderTitleFontSize))
                .tracking(0.9)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: layout.faderTitleWidth)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.9))
        }
    }

    private var faderRail: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x080808), Color(hex: 0x161616), Color(hex: 0x080808)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: layout.mode == .compact ? 6 : 7)
    }

    private var faderCap: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x45424D), Color(hex: 0x2E2B34)],
                        startPoint: .top,
                            endPoint: .bottom
                        )
                )
                .frame(width: layout.faderCapWidth, height: layout.faderCapHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(SpatialColor.accentLight.opacity(0.88))
                .frame(width: layout.faderCapWidth - 4, height: 2)
        }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    private var capOffset: CGFloat {
        ((0.5 - value) * usableTravelHeight)
    }

    private var usableTravelHeight: CGFloat {
        layout.faderTrackHeight - layout.faderCapHeight - 10
    }
}

private struct WidgetLinearSlider: View {
    let title: String
    let valueLabel: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(SpatialTypography.header(11))
                    .tracking(0.8)
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.84))

                Spacer()

                Text(valueLabel)
                    .font(SpatialTypography.header(14))
                    .foregroundStyle(SpatialColor.accentLight)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 8)

                    Capsule(style: .continuous)
                        .fill(SpatialColor.accent)
                        .frame(width: geometry.size.width * value, height: 8)

                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: SpatialColor.accent.opacity(0.35), radius: 8, y: 4)
                        .offset(x: max(0, geometry.size.width * value - 8))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let progress = gesture.location.x / max(1, geometry.size.width)
                            value = min(1, max(0, progress))
                        }
                )
            }
            .frame(height: 16)
        }
    }
}
