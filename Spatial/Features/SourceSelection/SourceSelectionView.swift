import AppKit
import SwiftUI

// #region agent log
private enum SourceSelectionAgentDebug {
    private static let logPath = "/Users/garuda/dev/spatial/.cursor/debug-0774d3.log"

    static func log(hypothesisId: String, message: String, data: [String: Any]) {
        let payload: [String: Any] = [
            "sessionId": "0774d3",
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "runId": "source-selection-crash",
            "hypothesisId": hypothesisId,
            "location": "SourceSelectionView",
            "message": message,
            "data": data
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: json, encoding: .utf8) else { return }
        line.append("\n")
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let url = URL(fileURLWithPath: logPath)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
// #endregion

@MainActor
final class SourceSelectionPanelState: ObservableObject {
    @Published var isExpanded = false

    func setExpanded(_ expanded: Bool, animated: Bool = true) {
        guard isExpanded != expanded else { return }

        if animated {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.12)) {
                isExpanded = expanded
            }
        } else {
            isExpanded = expanded
        }
    }

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }
}

struct SourceSelectionView: View {
    @ObservedObject var model: SpatialAppModel
    @ObservedObject var panelState: SourceSelectionPanelState
    var onConfigure: () -> Void = {}
    var onInitialize: () -> Void = {}

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    panelState.setExpanded(false)
                }

            notchBar
                .padding(.top, SpatialMetrics.sourceSelectionNotchTopPadding)
                .zIndex(1)

            if panelState.isExpanded {
                expandedCard
                    .padding(.top, expandedCardTopPadding)
                    .transition(.attachedDropdown)
                    .zIndex(0)
            }
        }
        .frame(
            width: SpatialMetrics.sourceSelectionWidth,
            height: panelState.isExpanded ? SpatialMetrics.sourceSelectionExpandedHeight : SpatialMetrics.sourceSelectionCollapsedHeight,
            alignment: .top
        )
    }

    private var notchBar: some View {
        Button(action: panelState.toggleExpanded) {
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
            .frame(width: 182, height: SpatialMetrics.sourceSelectionNotchHeight)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 14, y: 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
        .onTapGesture { }
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
                        // #region agent log
                        SourceSelectionAgentDebug.log(
                            hypothesisId: "H_source_card_action",
                            message: "source_card_tapped",
                            data: [
                                "source": source.rawValue,
                                "panelExpanded": panelState.isExpanded,
                                "currentlySelectedSource": model.selectedAudioSource?.rawValue ?? "nil"
                            ]
                        )
                        // #endregion
                        model.selectAudioSource(source)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer ()
            
            Button(action: onInitialize) {
                Text(model.sourceSelectionButtonTitle)
                    .font(SpatialTypography.text(14))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(
                        Capsule()
                            .fill(SpatialColor.accent)
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

    private var expandedCardTopPadding: CGFloat {
        SpatialMetrics.sourceSelectionNotchTopPadding
            + SpatialMetrics.sourceSelectionNotchHeight
            + SpatialMetrics.sourceSelectionNotchCardGap
    }
}

private struct AttachedDropdownModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isActive ? 0 : 1)
            .scaleEffect(x: 0.98, y: isActive ? 0.92 : 1, anchor: .top)
            .offset(y: isActive ? -10 : 0)
    }
}

private extension AnyTransition {
    static var attachedDropdown: AnyTransition {
        .modifier(
            active: AttachedDropdownModifier(isActive: true),
            identity: AttachedDropdownModifier(isActive: false)
        )
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

                    sourceIcon
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

    @ViewBuilder
    private var sourceIcon: some View {
        if let brandIcon = sourceBrandIcon {
            Image(nsImage: brandIcon)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .renderingMode(.original)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: source.symbolName)
                .font(SpatialTypography.text(18))
                .foregroundStyle(isSelected ? Color.black.opacity(0.7) : source.statusTint)
        }
    }

    private var sourceBrandIcon: NSImage? {
        guard let resource = source.brandIconResource else {
            return nil
        }

        let url = Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.extension,
            subdirectory: "Brand"
        ) ?? Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.extension
        )

        guard let url else {
            return nil
        }

        return NSImage(contentsOf: url)
    }
}
