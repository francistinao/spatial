import SwiftUI

struct OnboardingCardView: View {
    let state: SpatialAppState
    let primaryButtonTitle: String
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
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(SpatialColor.accentLight)
            }
            .padding(.top, -60)
            .padding(.bottom, 18)

            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    Text("Spatial needs one permission")
                        .font(.system(size: 22, weight: .medium, design: .default))
                        .foregroundStyle(SpatialColor.textPrimary)
                        .multilineTextAlignment(.center)

                    Text("To process your system audio in real-time, Spatial needs Screen Recording permission. For echo-free playback, route audio through a virtual device like BlackHole or Loopback. Your audio never leaves your device.")
                        .font(.system(size: 14, weight: .regular, design: .rounded))
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
                        .font(.system(size: 15, weight: .medium, design: .rounded))
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

                Button(action: onLearnMore) {
                    Text("Learn how this works")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(SpatialColor.accent)
                }
                .buttonStyle(.plain)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SpatialColor.activeGreen)

            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
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
