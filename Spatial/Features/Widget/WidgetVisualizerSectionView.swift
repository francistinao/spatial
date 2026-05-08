import SwiftUI

struct WidgetVisualizerSectionView: View {
    @ObservedObject var model: SpatialAppModel

    var body: some View {
        SectionCard(title: "Visualizer") {
            VisualizerBarsView(bars: model.visualizerBars)

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
                    title: model.isDriverReady ? "READY" : "SETUP",
                    tint: model.isDriverReady ? SpatialColor.activeGreen : SpatialColor.accent
                )
            }
        }
    }
}
