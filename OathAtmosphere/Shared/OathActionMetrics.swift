import Foundation

/// The welcome screen's action spacing, shared by every action area.
enum OathActionMetrics {
    static let spacing: CGFloat = 12
    static let labelSpacing: CGFloat = 10
    static let maximumWidth: CGFloat = 400
    static let glassClearance: CGFloat = 4

    static func screenMargin(for width: CGFloat) -> CGFloat {
        width < 380 ? 20 : 28
    }

    static func contentWidth(in availableWidth: CGFloat, existingInset: CGFloat = 0) -> CGFloat {
        let width = availableWidth.isFinite ? max(0, availableWidth) : maximumWidth
        let screenWidth = width + existingInset * 2
        let inset = screenMargin(for: screenWidth) + glassClearance
        return min(maximumWidth, width, max(0, screenWidth - inset * 2))
    }
}
