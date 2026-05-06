import SwiftUI

struct PillBadge: View {
    let title: String
    var tint: Color = SpatialColor.accent

    var body: some View {
        Text(title)
            .font(SpatialTypography.pill)
            .foregroundStyle(SpatialColor.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.18))
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.35), lineWidth: 1)
            )
            .clipShape(Capsule())
    }
}
