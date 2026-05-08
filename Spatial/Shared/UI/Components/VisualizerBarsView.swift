import SwiftUI

struct VisualizerBarsView: View {
    let bars: [CGFloat]

    private var displayBars: [CGFloat] {
        if bars.isEmpty {
            return Array(repeating: 0.08, count: 28)
        }
        return bars
    }

    private var activeIndex: Int {
        displayBars.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(displayBars.enumerated()), id: \.offset) { index, value in
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
