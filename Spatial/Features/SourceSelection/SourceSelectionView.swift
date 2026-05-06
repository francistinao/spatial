import SwiftUI

struct SourceSelectionView: View {
    @ObservedObject var model: SpatialAppModel
    var onConfigure: () -> Void = {}
    var onInitialize: () -> Void = {}
    @State private var isExpanded = false
    @State private var isPointerInsideNotch = false
    @State private var isPointerInsideCard = false
    @State private var pendingCollapseWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .top) {
            notchBar
                .padding(.top, 6)

            if isExpanded {
                expandedCard
                    .padding(.top, 34)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(
            width: SpatialMetrics.sourceSelectionWidth,
            height: isExpanded ? SpatialMetrics.sourceSelectionExpandedHeight : SpatialMetrics.sourceSelectionCollapsedHeight,
            alignment: .top
        )
    }

    private var notchBar: some View {
        HStack(spacing: 18) {
            Image(systemName: "waveform")
                .font(SpatialTypography.text(13))
                .foregroundStyle(Color.white.opacity(0.82))

            Circle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 8, height: 8)

            Image(systemName: "bell.slash")
                .font(SpatialTypography.text(12))
                .foregroundStyle(Color.white.opacity(0.78))
        }
        .padding(.horizontal, 28)
        .frame(width: 182, height: 36)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 6)
        .contentShape(Capsule())
        .onHover { hovering in
            isPointerInsideNotch = hovering

            if hovering {
                expandWidget()
            } else {
                scheduleCollapseIfNeeded()
            }
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            signalBanner
            sourceGrid
            footer
        }
        .padding(14)
        .frame(width: 476)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x1D1D1D), Color(hex: 0x171717), Color(hex: 0x131313)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.20), radius: 18, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            isPointerInsideCard = hovering

            if hovering {
                expandWidget()
            } else {
                scheduleCollapseIfNeeded()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x1E1E1E), Color(hex: 0x3A3A3A)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: "waveform.path")
                        .font(SpatialTypography.text(22))
                        .foregroundStyle(SpatialColor.textSecondary.opacity(0.55))
                )
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(SpatialTypography.text(14))
                    .foregroundStyle(SpatialColor.textPrimary)

                Text(headerSubtitle)
                    .font(SpatialTypography.header(11))
                    .tracking(1.4)
                    .foregroundStyle(SpatialColor.textSecondary)
            }

            Spacer()

            Image(systemName: "slider.horizontal.3")
                .font(SpatialTypography.text(15))
                .foregroundStyle(SpatialColor.textSecondary)
        }
    }

    private var signalBanner: some View {
        VStack(spacing: 10) {
            HStack(spacing: 16) {
                SignalGlyph(flipped: false)
                Text(model.sourceSelectionBannerTitle)
                    .font(SpatialTypography.mono)
                    .tracking(0.8)
                    .foregroundStyle(SpatialColor.textSecondary)
                SignalGlyph(flipped: true)
            }

            Text(model.sourceSelectionStatusText)
                .font(SpatialTypography.text(11))
                .foregroundStyle(SpatialColor.textSecondary.opacity(0.92))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
    }

    private var sourceGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SELECT AUDIO SOURCE")
                    .font(SpatialTypography.header(14))
                    .tracking(0.8)
                    .foregroundStyle(SpatialColor.textPrimary)

                Spacer()

                Text("4 ACTIVE")
                    .font(SpatialTypography.header(11))
                    .foregroundStyle(SpatialColor.accentLight)
            }

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                ForEach(AudioSourceOption.allCases) { source in
                    AudioSourceCard(
                        source: source,
                        isSelected: model.selectedAudioSource == source
                    ) {
                        model.selectAudioSource(source)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(action: onConfigure) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("Configuration")
                }
                .font(SpatialTypography.text(13))
                .foregroundStyle(SpatialColor.textSecondary)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onInitialize) {
                Text(model.sourceSelectionButtonTitle)
                    .font(SpatialTypography.text(14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: 0x8A63F2), SpatialColor.accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!model.canStartSelectedSource)
            .opacity(model.canStartSelectedSource ? 1 : 0.55)
        }
        .padding(.top, 4)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var headerTitle: String {
        if model.hasInitializedSelectedSource {
            return "Live Audio Connected"
        }

        if case .error = model.engineStatus {
            return "Live Capture Failed"
        }

        if model.isWaitingForScreenRecordingAuthorization {
            return model.isDriverBundleInstalledOnly ? "Spatial Speaker Unavailable" : "Spatial Speaker Needed"
        }

        if model.isStartingSelectedSource {
            return "Connecting Live Audio"
        }

        return "No Audio Detected"
    }

    private var headerSubtitle: String {
        model.engineStatusText.uppercased()
    }

    private func expandWidget() {
        pendingCollapseWorkItem?.cancel()

        guard !isExpanded else { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            isExpanded = true
        }
    }

    private func scheduleCollapseIfNeeded() {
        pendingCollapseWorkItem?.cancel()

        let workItem = DispatchWorkItem {
            guard !isPointerInsideNotch && !isPointerInsideCard else { return }

            withAnimation(.easeOut(duration: 0.18)) {
                isExpanded = false
            }
        }

        pendingCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }
}

private struct SignalGlyph: View {
    let flipped: Bool
    private let bars: [CGFloat] = [10, 16, 22, 15, 19, 13, 17]

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 4, height: height)
            }
        }
        .scaleEffect(x: flipped ? -1 : 1, y: 1)
    }
}

private struct AudioSourceCard: View {
    let source: AudioSourceOption
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(source.statusTint.opacity(isSelected ? 0.95 : 0.24))
                        .frame(width: 42, height: 42)

                    Image(systemName: source.symbolName)
                        .font(SpatialTypography.text(18))
                        .foregroundStyle(isSelected ? Color.black.opacity(0.7) : source.statusTint)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title)
                        .font(SpatialTypography.header(source == .systemAudio ? 13 : 15))
                        .foregroundStyle(SpatialColor.textPrimary)
                        .multilineTextAlignment(.leading)

                    Text(source.subtitle)
                        .font(SpatialTypography.text(11))
                        .foregroundStyle(SpatialColor.textSecondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color(hex: 0x4A4456) : Color.black.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? SpatialColor.accent.opacity(0.75) : Color.white.opacity(0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
