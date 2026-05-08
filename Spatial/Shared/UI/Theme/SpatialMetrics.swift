import CoreGraphics

enum SpatialMetrics {
    enum WidgetLayoutMode {
        case regular
        case compact
    }

    struct WidgetLayoutProfile {
        let mode: WidgetLayoutMode
        let width: CGFloat
        let expandedHeight: CGFloat
        let notchTopPadding: CGFloat
        let notchHeight: CGFloat
        let notchCardGap: CGFloat
        let cardCornerRadius: CGFloat
        let headerLogoHeight: CGFloat
        let headerControlSize: CGFloat
        let headerHorizontalPadding: CGFloat
        let headerTopPadding: CGFloat
        let headerBottomPadding: CGFloat
        let sectionHorizontalPadding: CGFloat
        let sectionTitleFontSize: CGFloat
        let sectionTitleTracking: CGFloat
        let helperTextFontSize: CGFloat
        let helperTextLineSpacing: CGFloat
        let visualizerHeight: CGFloat
        let visualizerBottomPadding: CGFloat
        let visualizerTitleFontSize: CGFloat
        let visualizerSubtitleFontSize: CGFloat
        let visualizerSubtitleSpacing: CGFloat
        let nowPlayingArtworkSize: CGFloat
        let nowPlayingHorizontalPadding: CGFloat
        let nowPlayingVerticalPadding: CGFloat
        let nowPlayingBottomPadding: CGFloat
        let nowPlayingTitleFontSize: CGFloat
        let nowPlayingSubtitleFontSize: CGFloat
        let badgeFontSize: CGFloat
        let badgeHorizontalPadding: CGFloat
        let badgeVerticalPadding: CGFloat
        let controlsBottomPadding: CGFloat
        let controlsSpacing: CGFloat
        let knobOuterSize: CGFloat
        let knobPrimaryRingSize: CGFloat
        let knobDarkRingSize: CGFloat
        let knobInnerRingSize: CGFloat
        let knobIndicatorWidth: CGFloat
        let knobIndicatorHeight: CGFloat
        let knobIndicatorOffsetY: CGFloat
        let knobValueFontSize: CGFloat
        let knobTitleFontSize: CGFloat
        let knobStackSpacing: CGFloat
        let slidersVerticalSpacing: CGFloat
        let sliderRowSpacing: CGFloat
        let slidersBottomPadding: CGFloat
        let faderTrackHeight: CGFloat
        let faderTrackWidth: CGFloat
        let faderCapWidth: CGFloat
        let faderCapHeight: CGFloat
        let faderValueFontSize: CGFloat
        let faderTitleFontSize: CGFloat
        let faderStackSpacing: CGFloat
        let faderTitleWidth: CGFloat
        let presetsSpacing: CGFloat
        let presetGridMinimum: CGFloat
        let presetGridSpacing: CGFloat
        let presetVerticalPadding: CGFloat
        let presetFontSize: CGFloat
        let presetsBottomPadding: CGFloat
        let footerHorizontalPadding: CGFloat
        let footerVerticalPadding: CGFloat
        let footerIconWidth: CGFloat
        let footerPrimaryFontSize: CGFloat
        let footerPrimaryTracking: CGFloat
        let footerSecondaryFontSize: CGFloat
    }

    static let popoverWidth: CGFloat = 452
    static let widgetExpandedHeight: CGFloat = 1000
    static let widgetCollapsedHeight: CGFloat = 90
    static let widgetNotchTopPadding: CGFloat = 6
    static let widgetNotchHeight: CGFloat = 36
    static let widgetNotchCardGap: CGFloat = 12
    static let settingsPopoverWidth: CGFloat = 320
    static let settingsPopoverHeight: CGFloat = 500
    static let sourceSelectionWidth: CGFloat = 520
    static let sourceSelectionExpandedHeight: CGFloat = 560
    static let sourceSelectionCollapsedHeight: CGFloat = 54
    static let sourceSelectionNotchTopPadding: CGFloat = 6
    static let sourceSelectionNotchHeight: CGFloat = 36
    static let sourceSelectionNotchCardGap: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 14
    static let sectionSpacing: CGFloat = 12
    static let outerPadding: CGFloat = 14
    static let controlSpacing: CGFloat = 10
    static let borderWidth: CGFloat = 1

    static func widgetLayout(for availableHeight: CGFloat) -> WidgetLayoutProfile {
        let compactThreshold: CGFloat = 980
        if availableHeight <= compactThreshold {
            return WidgetLayoutProfile(
                mode: .compact,
                width: 436,
                expandedHeight: 854,
                notchTopPadding: widgetNotchTopPadding,
                notchHeight: widgetNotchHeight,
                notchCardGap: widgetNotchCardGap,
                cardCornerRadius: 22,
                headerLogoHeight: 74,
                headerControlSize: 30,
                headerHorizontalPadding: 16,
                headerTopPadding: 10,
                headerBottomPadding: 8,
                sectionHorizontalPadding: 16,
                sectionTitleFontSize: 10,
                sectionTitleTracking: 0.95,
                helperTextFontSize: 9,
                helperTextLineSpacing: 1.5,
                visualizerHeight: 106,
                visualizerBottomPadding: 10,
                visualizerTitleFontSize: 10,
                visualizerSubtitleFontSize: 9,
                visualizerSubtitleSpacing: 1,
                nowPlayingArtworkSize: 48,
                nowPlayingHorizontalPadding: 12,
                nowPlayingVerticalPadding: 9,
                nowPlayingBottomPadding: 10,
                nowPlayingTitleFontSize: 13,
                nowPlayingSubtitleFontSize: 11,
                badgeFontSize: 9,
                badgeHorizontalPadding: 8,
                badgeVerticalPadding: 5,
                controlsBottomPadding: 12,
                controlsSpacing: 12,
                knobOuterSize: 54,
                knobPrimaryRingSize: 48,
                knobDarkRingSize: 40,
                knobInnerRingSize: 36,
                knobIndicatorWidth: 4,
                knobIndicatorHeight: 14,
                knobIndicatorOffsetY: 12,
                knobValueFontSize: 16,
                knobTitleFontSize: 8,
                knobStackSpacing: 5,
                slidersVerticalSpacing: 12,
                sliderRowSpacing: 14,
                slidersBottomPadding: 14,
                faderTrackHeight: 124,
                faderTrackWidth: 32,
                faderCapWidth: 42,
                faderCapHeight: 24,
                faderValueFontSize: 17,
                faderTitleFontSize: 8,
                faderStackSpacing: 8,
                faderTitleWidth: 64,
                presetsSpacing: 8,
                presetGridMinimum: 84,
                presetGridSpacing: 8,
                presetVerticalPadding: 9,
                presetFontSize: 12,
                presetsBottomPadding: 12,
                footerHorizontalPadding: 14,
                footerVerticalPadding: 10,
                footerIconWidth: 22,
                footerPrimaryFontSize: 9,
                footerPrimaryTracking: 0.7,
                footerSecondaryFontSize: 8
            )
        }

        return WidgetLayoutProfile(
            mode: .regular,
            width: popoverWidth,
            expandedHeight: widgetExpandedHeight,
            notchTopPadding: widgetNotchTopPadding,
            notchHeight: widgetNotchHeight,
            notchCardGap: widgetNotchCardGap,
            cardCornerRadius: 24,
            headerLogoHeight: 90,
            headerControlSize: 34,
            headerHorizontalPadding: 18,
            headerTopPadding: 12,
            headerBottomPadding: 10,
            sectionHorizontalPadding: 18,
            sectionTitleFontSize: 11,
            sectionTitleTracking: 1.1,
            helperTextFontSize: 10,
            helperTextLineSpacing: 2,
            visualizerHeight: 122,
            visualizerBottomPadding: 14,
            visualizerTitleFontSize: 11,
            visualizerSubtitleFontSize: 10,
            visualizerSubtitleSpacing: 2,
            nowPlayingArtworkSize: 54,
            nowPlayingHorizontalPadding: 14,
            nowPlayingVerticalPadding: 10,
            nowPlayingBottomPadding: 14,
            nowPlayingTitleFontSize: 15,
            nowPlayingSubtitleFontSize: 12,
            badgeFontSize: 10,
            badgeHorizontalPadding: 9,
            badgeVerticalPadding: 6,
            controlsBottomPadding: 18,
            controlsSpacing: 18,
            knobOuterSize: 60,
            knobPrimaryRingSize: 54,
            knobDarkRingSize: 44,
            knobInnerRingSize: 40,
            knobIndicatorWidth: 5,
            knobIndicatorHeight: 16,
            knobIndicatorOffsetY: 13,
            knobValueFontSize: 19,
            knobTitleFontSize: 9,
            knobStackSpacing: 7,
            slidersVerticalSpacing: 18,
            sliderRowSpacing: 22,
            slidersBottomPadding: 20,
            faderTrackHeight: 148,
            faderTrackWidth: 38,
            faderCapWidth: 50,
            faderCapHeight: 28,
            faderValueFontSize: 20,
            faderTitleFontSize: 10,
            faderStackSpacing: 10,
            faderTitleWidth: 72,
            presetsSpacing: 10,
            presetGridMinimum: 92,
            presetGridSpacing: 10,
            presetVerticalPadding: 11,
            presetFontSize: 13,
            presetsBottomPadding: 18,
            footerHorizontalPadding: 16,
            footerVerticalPadding: 12,
            footerIconWidth: 24,
            footerPrimaryFontSize: 10,
            footerPrimaryTracking: 0.8,
            footerSecondaryFontSize: 9
        )
    }
}
