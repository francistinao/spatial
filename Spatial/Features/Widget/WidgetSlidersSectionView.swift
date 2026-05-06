import SwiftUI

struct WidgetSlidersSectionView: View {
    let settings: SpatialSettings

    var body: some View {
        SectionCard(title: "Motion") {
            SliderRow(title: "Speed", valueText: "\(Int(settings.speed))", progress: settings.speed / 5.0)
            SliderRow(title: "Elevation", valueText: "\(Int(settings.elevation * 100))%", progress: settings.elevation)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let valueText: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(SpatialTypography.label)
                    .foregroundStyle(SpatialColor.textSecondary)

                Spacer()

                Text(valueText)
                    .font(SpatialTypography.value)
                    .foregroundStyle(SpatialColor.textPrimary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(SpatialColor.border)
                        .frame(height: 6)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [SpatialColor.accentLight, SpatialColor.accent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * progress, height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}
