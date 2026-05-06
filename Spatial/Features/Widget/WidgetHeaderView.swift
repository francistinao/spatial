import SwiftUI

struct WidgetHeaderView: View {
    @ObservedObject var model: SpatialAppModel
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("logo")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(SpatialColor.textPrimary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text("SPATIAL")
                    .font(SpatialTypography.header(17))
                    .foregroundStyle(SpatialColor.textPrimary)
                    .tracking(1.3)

                Text("8D AUDIO ENGINE")
                    .font(SpatialTypography.pill)
                    .foregroundStyle(SpatialColor.accent)
                    .tracking(1.2)
            }

            Spacer()

            Button(action: model.togglePower) {
                PillBadge(
                    title: model.state.isEnabled ? "ON" : "OFF",
                    tint: model.state.isEnabled ? SpatialColor.activeGreen : SpatialColor.textTertiary
                )
            }
            .buttonStyle(.plain)

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .foregroundStyle(SpatialColor.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }
}
