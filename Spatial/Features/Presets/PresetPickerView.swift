import SwiftUI

struct PresetPickerView: View {
    let presets: [SpatialPreset]
    let selectedPreset: SpatialPresetKind
    let onSelect: (SpatialPresetKind) -> Void

    var body: some View {
        SectionCard(title: "Presets") {
            HStack(spacing: 8) {
                ForEach(presets) { preset in
                    Button(action: { onSelect(preset.kind) }) {
                        Text(preset.kind.displayName)
                            .font(SpatialTypography.pill)
                            .foregroundStyle(SpatialColor.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                Capsule()
                                    .fill(preset.kind == selectedPreset ? SpatialColor.accent.opacity(0.28) : SpatialColor.background)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(
                                        preset.kind == selectedPreset ? SpatialColor.accent : SpatialColor.border,
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
