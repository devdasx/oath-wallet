import Foundation

/// Shared unlock-keypad proportions, independent of screen height.
enum OathKeypadGeometry {
    static let letters = ["", "", "ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"]
    static let minimumDiameter: CGFloat = 44
    static let circularDiameter: CGFloat = 88
    static let circularColumnSpacing: CGFloat = 24
    static let circularRowSpacing: CGFloat = 20

    static func circularSize(diameter: CGFloat) -> CGSize {
        let diameter = max(minimumDiameter, diameter.isFinite ? diameter : circularDiameter)
        return CGSize(width: diameter * 3 + circularColumnSpacing * 2,
                      height: diameter * 4 + circularRowSpacing * 3)
    }

    /// Fit compact phones horizontally; scroll vertically instead of shrinking
    /// the controls when text grows or a sheet provides less height.
    static func size(fittingWidth width: CGFloat, preferredDiameter: CGFloat) -> CGSize {
        let width = width.isFinite ? max(0, width) : 0
        let preferred = preferredDiameter.isFinite ? max(minimumDiameter, preferredDiameter) : circularDiameter
        let diameter = min(preferred, max(minimumDiameter, (width - circularColumnSpacing * 2) / 3))
        return circularSize(diameter: diameter)
    }

    /// Physical digit positions are invariant, just like the system PIN pad.
    /// The app's prose can mirror without mirroring numeric row order.
    static func circularFrame(row: Int, column: Int, size: CGSize) -> CGRect {
        guard (0..<4).contains(row), (0..<3).contains(column),
              size.width.isFinite, size.height.isFinite,
              size.width > circularColumnSpacing * 2, size.height > circularRowSpacing * 3 else { return .zero }
        let diameter = min((size.width - circularColumnSpacing * 2) / 3,
                           (size.height - circularRowSpacing * 3) / 4)
        let startX = (size.width - diameter * 3 - circularColumnSpacing * 2) / 2
        let startY = (size.height - diameter * 4 - circularRowSpacing * 3) / 2
        return CGRect(x: startX + CGFloat(column) * (diameter + circularColumnSpacing),
                      y: startY + CGFloat(row) * (diameter + circularRowSpacing),
                      width: diameter, height: diameter)
    }
}
