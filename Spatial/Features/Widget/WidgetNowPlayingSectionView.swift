import SwiftUI

struct WidgetNowPlayingSectionView: View {
    let nowPlaying: NowPlayingInfo

    var body: some View {
        SectionCard(title: "Now Playing") {
            VStack(alignment: .leading, spacing: 6) {
                Text(nowPlaying.trackName)
                    .font(SpatialTypography.cardTitle)
                    .foregroundStyle(SpatialColor.textPrimary)

                Text(nowPlaying.artistName)
                    .font(SpatialTypography.body)
                    .foregroundStyle(SpatialColor.textSecondary)

                HStack {
                    PillBadge(title: nowPlaying.sourceName, tint: SpatialColor.accent)
                    PillBadge(
                        title: nowPlaying.isPlaying ? "PLAYING" : "PAUSED",
                        tint: nowPlaying.isPlaying ? SpatialColor.activeGreen : SpatialColor.textTertiary
                    )
                }
            }
        }
    }
}
