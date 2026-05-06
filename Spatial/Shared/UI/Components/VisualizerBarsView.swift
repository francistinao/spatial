import SwiftUI

struct VisualizerBarsView: View {
    let activeIndex: Int

    private let values: [CGFloat] = [
        0.20, 0.34, 0.48, 0.62, 0.55, 0.40, 0.78, 0.65,
        0.30, 0.22, 0.38, 0.50, 0.74, 0.68, 0.44, 0.29,
        0.25, 0.31, 0.42, 0.61, 0.72, 0.64, 0.47, 0.33,
        0.24, 0.19, 0.27, 0.41, 0.53, 0.59, 0.49, 0.35
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index == activeIndex ? SpatialColor.accentLight : SpatialColor.accent.opacity(0.55))
                        .frame(width: 5, height: 58 * value + 10)
                }
            }

            HStack {
                Text("PAN ORBIT")
                    .font(SpatialTypography.mono)
                    .foregroundStyle(SpatialColor.textTertiary)

                Spacer()

                Circle()
                    .fill(SpatialColor.accentLight)
                    .frame(width: 8, height: 8)

                Text("LFO")
                    .font(SpatialTypography.mono)
                    .foregroundStyle(SpatialColor.textSecondary)
            }
        }
    }
}
