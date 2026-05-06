import SwiftUI

struct OnboardingCardView: View {
    let state: SpatialAppState
    let primaryButtonTitle: String
    var primaryButtonDisabled: Bool = false
    var detailText: String
    var statusText: String?
    var onPrimaryAction: () -> Void = {}
    var onLearnMore: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 74, height: 74)

                Circle()
                    .stroke(SpatialColor.accent.opacity(0.08), lineWidth: 1)
                    .frame(width: 102, height: 102)

                Circle()
                    .stroke(SpatialColor.accent.opacity(0.05), lineWidth: 1)
                    .frame(width: 128, height: 128)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.09), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 52, height: 52)

                Image(systemName: "headphones")
                    .font(SpatialTypography.header(24))
                    .foregroundStyle(SpatialColor.accentLight)
            }
            .padding(.top, -60)
            .padding(.bottom, 18)

            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    Text("Spatial needs one audio driver")
                        .font(SpatialTypography.header(22))
                        .foregroundStyle(SpatialColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(detailText)
                        .font(SpatialTypography.text(14))
                        .foregroundStyle(SpatialColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    OnboardingBenefitPill(
                        title: "No recording",
                        systemImage: "lock.fill"
                    )
                    OnboardingBenefitPill(
                        title: "Offline only",
                        systemImage: "wifi.slash"
                    )
                    OnboardingBenefitPill(
                        title: "Zero data",
                        systemImage: "shield"
                    )
                }
                .frame(maxWidth: .infinity)

                Button(action: onPrimaryAction) {
                    Text(primaryButtonTitle)
                        .font(SpatialTypography.text(15))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: 0x8A63F2), SpatialColor.accent],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .shadow(color: SpatialColor.accent.opacity(0.40), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
                .disabled(primaryButtonDisabled)
                .opacity(primaryButtonDisabled ? 0.7 : 1)

                Button(action: onLearnMore) {
                    Text("Learn how this works")
                        .font(SpatialTypography.text(14))
                        .foregroundStyle(SpatialColor.accent)
                }
                .buttonStyle(.plain)

                if let statusText, !statusText.isEmpty {
                    Text(statusText)
                        .font(SpatialTypography.text(12))
                        .foregroundStyle(state.screenRecordingAuthorized ? SpatialColor.activeGreen : SpatialColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 22)
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(hex: 0x1A1A1B).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 35, y: 20)
    }
}

private struct OnboardingBenefitPill: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(SpatialTypography.header(11))
                .foregroundStyle(SpatialColor.activeGreen)

            Text(title)
                .font(SpatialTypography.text(12))
                .foregroundStyle(SpatialColor.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}
