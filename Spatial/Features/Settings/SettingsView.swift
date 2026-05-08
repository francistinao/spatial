import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SpatialAppModel

    var body: some View {
        ZStack {
            SpatialColor.background.ignoresSafeArea()

            settingsCard
                .frame(
                    width: SpatialMetrics.settingsPopoverWidth,
                    height: SpatialMetrics.settingsPopoverHeight,
                    alignment: .top
                )
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 18) {
                sourceSection
                monitorOutputSection
                presetSection
                themeSection
                launchSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 18)

            Spacer(minLength: 0)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(hex: 0x1E1B1D))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(SpatialColor.accent.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: SpatialColor.accent.opacity(0.12), radius: 18, y: 10)
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(SpatialTypography.header(14))
                .foregroundStyle(SpatialColor.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Audio source")

            Menu {
                ForEach(AudioSourceOption.allCases) { source in
                    Button(action: { model.selectAudioSource(source) }) {
                        if model.selectedAudioSource == source {
                            Label(source.menuTitle, systemImage: "checkmark")
                        } else {
                            Text(source.menuTitle)
                        }
                    }
                }
            } label: {
                selectorRow(
                    title: model.selectedAudioSource?.menuTitle ?? "No Source",
                    subtitle: nil
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var monitorOutputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("8D monitor output")

            Menu {
                Button(action: { model.updateMonitorOutputDeviceUID(nil) }) {
                    if model.settings.monitorOutputDeviceUID == nil {
                        Label("Automatic", systemImage: "checkmark")
                    } else {
                        Text("Automatic")
                    }
                }

                ForEach(model.availableMonitorOutputs, id: \.uid) { device in
                    Button(action: { model.updateMonitorOutputDeviceUID(device.uid) }) {
                        if model.settings.monitorOutputDeviceUID == device.uid {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                selectorRow(
                    title: model.selectedMonitorOutputTitle,
                    subtitle: "Spatial Speaker receives the dry system audio while Spatial plays the tuned 8D signal here."
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Spatial preset")

            HStack(spacing: 8) {
                ForEach(model.presets) { preset in
                    Button(action: { model.selectPreset(preset.kind) }) {
                        Text(preset.kind.displayName)
                            .font(SpatialTypography.text(11))
                            .foregroundStyle(
                                model.selectedPreset == preset.kind
                                    ? Color.white
                                    : SpatialColor.textSecondary
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        model.selectedPreset == preset.kind
                                            ? SpatialColor.accent
                                            : Color.white.opacity(0.06)
                                    )
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(
                                        model.selectedPreset == preset.kind
                                            ? SpatialColor.accentLight.opacity(0.7)
                                            : Color.white.opacity(0.06),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Theme color")

            HStack(spacing: 10) {
                ForEach(SpatialTheme.allCases) { theme in
                    Button(action: { model.updateTheme(theme) }) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(hex: theme.accentHex))
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        model.settings.theme == theme
                                            ? Color.white.opacity(0.94)
                                            : Color.white.opacity(0.08),
                                        lineWidth: model.settings.theme == theme ? 2 : 1
                                    )
                            }
                            .overlay {
                                if model.settings.theme == theme {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                        .padding(4)
                                }
                            }
                            .shadow(color: Color(hex: theme.accentHex).opacity(0.30), radius: 8, y: 4)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
                    .help(theme.displayName)
                }
            }
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Launch at login")
                    .font(SpatialTypography.text(13))
                    .foregroundStyle(SpatialColor.textPrimary.opacity(0.88))

                Spacer()

                Toggle("", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLoginEnabled($0) }
                ))
                .toggleStyle(AccentSwitchToggleStyle())
                .labelsHidden()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: quitApplication) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .font(SpatialTypography.text(11))

                    Text("Quit")
                        .font(SpatialTypography.header(11))
                }
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            Text("Spatial 1.0.0")
                .font(SpatialTypography.text(11))
                .foregroundStyle(SpatialColor.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func selectorRow(title: String, subtitle: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: subtitle == nil ? 0 : 2) {
                Text(title)
                    .font(SpatialTypography.text(13))
                    .foregroundStyle(SpatialColor.textPrimary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(SpatialTypography.text(10))
                        .foregroundStyle(SpatialColor.textSecondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: "chevron.down")
                .font(SpatialTypography.text(11))
                .foregroundStyle(SpatialColor.accentLight)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.50))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(SpatialTypography.text(11))
            .tracking(0.6)
            .foregroundStyle(SpatialColor.textSecondary.opacity(0.95))
    }

    private func quitApplication() {
        NSApp.terminate(nil)
    }
}

private extension AudioSourceOption {
    var menuTitle: String {
        title.replacingOccurrences(of: "\n", with: " ")
    }
}

private struct AccentSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(configuration.isOn ? SpatialColor.activeGreen : Color.white.opacity(0.10))
                    .frame(width: 46, height: 26)

                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .padding(3)
            }
            .animation(.easeInOut(duration: 0.16), value: configuration.isOn)
        }
        .buttonStyle(.plain)
    }
}
