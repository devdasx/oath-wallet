import SwiftUI
import UIKit

extension WalletTheme {
    /// Flat, adaptive system colors for the 20 visible recent-recipient tiles.
    /// Additional shades are solid fills, never gradients or row-wide tints.
    enum RecipientIconColor: Int, CaseIterable, Sendable {
        case blue, indigo, purple, pink, red, orange, green, mint, teal, cyan
        case shadedBlue, shadedIndigo, shadedPurple, shadedPink, shadedRed
        case shadedOrange, shadedGreen, shadedMint, shadedTeal, shadedCyan

        var background: Color {
            Color(uiColor: UIColor { traits in resolvedBackground(with: traits) })
        }

        var foreground: Color {
            WalletTheme.onDarkColorLabel
        }

        private var base: UIColor {
            switch rawValue % 10 {
            case 0: .systemBlue
            case 1: .systemIndigo
            case 2: .systemPurple
            case 3: .systemPink
            case 4: .systemRed
            case 5: .systemOrange
            case 6: .systemGreen
            case 7: .systemMint
            case 8: .systemTeal
            default: .systemCyan
            }
        }

        private func resolvedBackground(with traits: UITraitCollection) -> UIColor {
            let color = base.resolvedColor(with: traits)
            guard rawValue >= 10 else { return color }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return color }
            // A solid darker shade in light appearance, lighter in dark.
            let target: CGFloat = traits.userInterfaceStyle == .dark ? 1 : 0
            let amount: CGFloat = 0.28
            return UIColor(
                red: red + (target - red) * amount,
                green: green + (target - green) * amount,
                blue: blue + (target - blue) * amount,
                alpha: 1
            )
        }
    }
}
