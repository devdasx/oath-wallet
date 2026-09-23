import SwiftUI

/// A static, evenly spaced grid that scales with the card's bounds.
struct WalletHomeBalanceCardGrid: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return Path() }

        let spacing = WalletHomeBalanceCardMetrics.gridSpacing
        let firstX = rect.minX + rect.width.truncatingRemainder(dividingBy: spacing) / 2
        let firstY = rect.minY + rect.height.truncatingRemainder(dividingBy: spacing) / 2
        var path = Path()
        for x in stride(from: firstX, through: rect.maxX, by: spacing) {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for y in stride(from: firstY, through: rect.maxY, by: spacing) {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
