import SwiftUI

struct SettingsView: View {
    let settings: SpatialSettings
    let launchAtLoginEnabled: Bool

    var body: some View {
        ZStack {
            SpatialColor.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: SpatialMetrics.sectionSpacing) {
                Text("Settings")
                    .font(SpatialTypography.headline)
                    .foregroundStyle(SpatialColor.textPrimary)

                SectionCard(title: "Startup") {
                    SettingRow(label: "Launch at Login", value: launchAtLoginEnabled ? "Enabled" : "Disabled")
                    SettingRow(label: "Target", value: "Default Output")
                }

                SectionCard(title: "Rotation Pattern") {
                    SettingRow(label: "Pattern", value: "Sine")
                    SettingRow(label: "Speed", value: "\(Int(settings.speed))")
                }

                SectionCard(title: "Global Hotkey") {
                    SettingRow(label: "Status", value: "Deferred")
                    SettingRow(label: "Binding", value: "--")
                }

                Spacer(minLength: 0)
            }
            .padding(SpatialMetrics.outerPadding)
            .frame(width: SpatialMetrics.popoverWidth)
        }
    }
}

private struct SettingRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(SpatialTypography.label)
                .foregroundStyle(SpatialColor.textSecondary)

            Spacer()

            Text(value)
                .font(SpatialTypography.value)
                .foregroundStyle(SpatialColor.textPrimary)
        }
    }
}
