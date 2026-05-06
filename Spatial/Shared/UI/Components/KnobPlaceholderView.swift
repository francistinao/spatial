import SwiftUI

struct KnobPlaceholderView: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(SpatialColor.border, lineWidth: 8)
                    .frame(width: 62, height: 62)

                Circle()
                    .trim(from: 0, to: max(0.08, value))
                    .stroke(
                        AngularGradient(colors: [SpatialColor.accentLight, SpatialColor.accent], center: .center),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(135))
                    .frame(width: 62, height: 62)

                Text("\(Int(value * 100))")
                    .font(SpatialTypography.value)
                    .foregroundStyle(SpatialColor.textPrimary)
            }

            Text(title)
                .font(SpatialTypography.label)
                .foregroundStyle(SpatialColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}
