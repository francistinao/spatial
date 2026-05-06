import SwiftUI

struct WidgetRootView: View {
    @ObservedObject var model: SpatialAppModel
    let openSettings: () -> Void

    @State private var isPointerInsideNotch = false
    @State private var isPointerInsideCard = false
    @State private var pendingCollapseWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .top) {
            notchBar
                .padding(.top, 6)

            if model.widgetDisplayMode == .expanded {
                ExpandedWidgetView(model: model, openSettings: openSettings)
                    .padding(.top, 34)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .onHover { hovering in
                        isPointerInsideCard = hovering

                        if !hovering {
                            scheduleCollapseIfNeeded()
                        } else {
                            pendingCollapseWorkItem?.cancel()
                        }
                    }
            }
        }
        .frame(
            width: SpatialMetrics.popoverWidth,
            height: model.widgetDisplayMode == .expanded ? SpatialMetrics.widgetExpandedHeight : SpatialMetrics.widgetCollapsedHeight,
            alignment: .top
        )
    }

    private var notchBar: some View {
        CollapsedWidgetView(model: model)
            .onTapGesture {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                    model.expandWidget()
                }
            }
            .onHover { hovering in
                isPointerInsideNotch = hovering

                if !hovering {
                    scheduleCollapseIfNeeded()
                } else {
                    pendingCollapseWorkItem?.cancel()
                }
            }
    }

    private func scheduleCollapseIfNeeded() {
        pendingCollapseWorkItem?.cancel()

        guard model.widgetDisplayMode == .expanded else { return }

        let workItem = DispatchWorkItem {
            guard !isPointerInsideNotch && !isPointerInsideCard else { return }

            withAnimation(.easeOut(duration: 0.18)) {
                model.collapseWidgetIfPossible()
            }
        }

        pendingCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}

private struct ExpandedWidgetView: View {
    @ObservedObject var model: SpatialAppModel
    let openSettings: () -> Void

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
        .padding(.top, 8)
        .background(widgetBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.42), radius: 24, y: 16)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("SPATIAL")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.92))

            Spacer()

            Button(action: model.togglePower) {
                ZStack {
                    Circle()
                        .fill(Color(hex: 0x271E3F))
                        .frame(width: 34, height: 34)

                    Circle()
                        .stroke(SpatialColor.accent.opacity(0.42), lineWidth: 1)
                        .frame(width: 34, height: 34)

                    Image(systemName: model.state.isEnabled ? "waveform.path.ecg" : "power")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.state.isEnabled ? SpatialColor.accentLight : SpatialColor.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var positionVisualizer: some View {
        VStack(spacing: 8) {
            VisualizerPanel(bars: model.visualizerBars)
                .frame(height: 122)

            VStack(spacing: 2) {
                Text("8D POSITION")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.82))

                Text(positionVisualizerSubtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SpatialColor.textSecondary.opacity(0.9))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
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

                Image(systemName: model.displayArtworkSystemName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(SpatialColor.accentLight.opacity(0.85))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.collapsedTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SpatialColor.textPrimary)
                    .lineLimit(1)

                Text(model.displayArtistName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SpatialColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            SourceBadge(source: model.selectedAudioSource)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("8D CONTROLS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.82))

            HStack(spacing: 14) {
                CircularDialControl(title: "ROTATE", value: binding(for: \.rotation))
                CircularDialControl(title: "DEPTH", value: binding(for: \.depth))
                CircularDialControl(title: "AMBIENCE", value: binding(for: \.reverb))
                CircularDialControl(title: "WIDTH", value: binding(for: \.width))
            }

            Text("Rotate sets side-to-side orbit span. Depth controls binaural intensity. Ambience adds space. Width expands stereo spread.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SpatialColor.textSecondary.opacity(0.92))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var sliders: some View {
        VStack(spacing: 14) {
            WidgetLinearSlider(
                title: "ORBIT SPEED",
                valueLabel: "\(Int(model.settings.speed))",
                value: Binding(
                    get: { model.settings.speed / 10.0 },
                    set: { model.updateSpeed(max(1, min(10, $0 * 10.0))) }
                )
            )

            WidgetLinearSlider(
                title: "VERTICAL ARC",
                valueLabel: "\(Int(model.settings.elevation * 100))%",
                value: binding(for: \.elevation)
            )

            Text("Orbit Speed changes how fast sound circles around you. Vertical Arc lifts the path above and below ear level.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SpatialColor.textSecondary.opacity(0.92))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRESETS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.9)
                .foregroundStyle(SpatialColor.textPrimary.opacity(0.82))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                ForEach(model.presets) { preset in
                    Button(action: { model.selectPreset(preset.kind) }) {
                        Text(preset.kind.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .tracking(0.4)
                            .foregroundStyle(SpatialColor.textPrimary.opacity(model.selectedPreset == preset.kind ? 1 : 0.86))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(model.selectedPreset == preset.kind ? SpatialColor.accent.opacity(0.28) : Color.white.opacity(0.06))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(model.selectedPreset == preset.kind ? SpatialColor.accent : Color.white.opacity(0.06), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.9))
                    .frame(width: 24)
            }
            .buttonStyle(.plain)

            Button(action: model.collapseWidgetIfPossible) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(SpatialColor.textSecondary)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(model.engineStatusText.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(SpatialColor.accentLight)

                Text(model.spatialTuningSummary)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(SpatialColor.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.18))
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
                default:
                    break
                }
            }
        )
    }
}

private struct CollapsedWidgetView: View {
    @ObservedObject var model: SpatialAppModel

    var body: some View {
        HStack(spacing: 12) {
            CompactVisualizerGlyph(bars: Array(model.visualizerBars.prefix(4)))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(model.collapsedTitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(SpatialColor.textPrimary)
                        .lineLimit(1)

                    SourceBadge(source: model.selectedAudioSource)
                }

                Text(model.collapsedSubtitle)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(SpatialColor.textSecondary.opacity(0.94))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            CompactVisualizerGlyph(bars: Array(model.visualizerBars.suffix(4)))
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

    var body: some View {
        VStack {
            Spacer()

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SpatialColor.accent.opacity(0.78), SpatialColor.accentLight],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 5, height: max(12, value * 84))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                Rectangle()
                    .fill(SpatialColor.accentLight.opacity(0.82))
                    .frame(width: 3.5, height: max(9, value * 18))
            }
        }
        .frame(height: 22, alignment: .bottom)
    }
}

private struct SourceBadge: View {
    let source: AudioSourceOption?

    var body: some View {
        Text(source?.title.replacingOccurrences(of: "\n", with: " ") ?? "None")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.2)
            .foregroundStyle(source?.statusTint ?? SpatialColor.textTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
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

private struct CircularDialControl: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)

                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 7)

                    Circle()
                        .trim(from: 0, to: max(0.03, value))
                        .stroke(
                            AngularGradient(
                                colors: [SpatialColor.accentLight, SpatialColor.accent],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    Text("\(Int(value * 100))%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(SpatialColor.textPrimary)
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                            let vector = CGVector(dx: gesture.location.x - center.x, dy: gesture.location.y - center.y)
                            let angle = atan2(vector.dy, vector.dx) + .pi / 2
                            let wrapped = angle < 0 ? angle + (.pi * 2) : angle
                            value = min(1, max(0, wrapped / (.pi * 2)))
                        }
                )
            }
            .frame(width: 58, height: 58)

            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(SpatialColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
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
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.84))

                Spacer()

                Text(valueLabel)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(SpatialColor.accentLight)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 8)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [SpatialColor.accentLight, SpatialColor.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
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
