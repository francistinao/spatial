import SwiftUI

struct WidgetVisualizerSectionView: View {
    @ObservedObject var model: SpatialAppModel

    var body: some View {
        SectionCard(title: "Visualizer") {
            VisualizerBarsView(activeIndex: 18)

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.engineStatusText)
                        .font(SpatialTypography.cardTitle)
                        .foregroundStyle(SpatialColor.textPrimary)

                    Text(model.state.recommendedOutput)
                        .font(SpatialTypography.label)
                        .foregroundStyle(SpatialColor.textSecondary)
                }

                Spacer()

                PillBadge(
                    title: model.state.screenRecordingAuthorized ? "READY" : "SETUP",
                    tint: model.state.screenRecordingAuthorized ? SpatialColor.activeGreen : SpatialColor.accent
                )
            }
        }
    }
}
