import SwiftUI

enum SpatialTypography {
    static let sectionLabel = Font.custom("Helvetica-Bold", size: 11)
    static let pill = Font.custom("Helvetica-Bold", size: 11)
    static let label = Font.custom("Poppins-Regular", size: 12)
    static let cardTitle = Font.custom("Helvetica-Bold", size: 13)
    static let body = Font.custom("Poppins-Regular", size: 14)
    static let value = Font.custom("Helvetica-Bold", size: 14)
    static let headline = Font.custom("Helvetica-Bold", size: 22)
    static let heroNumber = Font.custom("Helvetica-Bold", size: 28)
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)

    static func header(_ size: CGFloat) -> Font { .custom("Helvetica-Bold", size: size) }
    static func text(_ size: CGFloat) -> Font { .custom("Poppins-Regular", size: size) }
}
