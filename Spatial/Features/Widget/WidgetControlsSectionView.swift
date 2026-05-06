import SwiftUI

struct WidgetControlsSectionView: View {
    let settings: SpatialSettings

    var body: some View {
        SectionCard(title: "8D Controls") {
            HStack(spacing: SpatialMetrics.controlSpacing) {
                KnobPlaceholderView(title: "Rotation", value: settings.rotation)
                KnobPlaceholderView(title: "Depth", value: settings.depth)
                KnobPlaceholderView(title: "Reverb", value: settings.reverb)
                KnobPlaceholderView(title: "Width", value: settings.width)
            }
        }
    }
}
