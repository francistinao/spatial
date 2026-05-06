import SwiftUI

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(SpatialTypography.sectionLabel)
                .foregroundStyle(SpatialColor.textTertiary)
                .tracking(0.8)

            content
        }
        .padding(SpatialMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SpatialColor.card)
        .overlay(
            RoundedRectangle(cornerRadius: SpatialMetrics.cardRadius)
                .stroke(SpatialColor.border, lineWidth: SpatialMetrics.borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: SpatialMetrics.cardRadius))
    }
}
