import SwiftUI

extension WalletTheme {
    static let balanceCardSurface = Color("BalanceCardSurface")
    static let balanceCardGrid = Color("BalanceCardGrid")
    static let balanceCardInk = Color("BalanceCardInk")
    static let balanceCardSecondaryInk = Color("BalanceCardSecondaryInk")
    static let balanceCardChipSurface = Color("BalanceCardChipSurface")
    static let balanceCardBorder = Color("BalanceCardBorder")
    static let balanceCardChipBorder = Color("BalanceCardChipBorder")
}

enum WalletHomeBalanceCardMetrics {
    // Digital payment-card artwork uses 1536 × 969. Accessibility content may
    // grow the height; iPad retains a card-sized surface instead of stretching it.
    static let aspectRatio: CGFloat = 1536.0 / 969.0
    static let maximumWidth: CGFloat = 440
    static let horizontalInset: CGFloat = 20
    static let contentInset: CGFloat = 22
    // Preserve the chip placement independently of decorative card artwork.
    static let chipTrailingInset: CGFloat = 34
    static let cornerRadius: CGFloat = 22
    static let gridSpacing: CGFloat = 28
    static let gridLineWidth: CGFloat = 0.5

    // An 11 × 8.3 mm contact module, proportional to an 85.60 mm payment card.
    static func chipSize(cardWidth: CGFloat) -> CGSize {
        CGSize(width: cardWidth * 11 / 85.60, height: cardWidth * 8.3 / 85.60)
    }
}

struct WalletHomeBalanceCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, min(proposal.width ?? WalletHomeBalanceCardMetrics.maximumWidth,
                               WalletHomeBalanceCardMetrics.maximumWidth))
        let content = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
        return CGSize(width: width, height: max(width / WalletHomeBalanceCardMetrics.aspectRatio, content.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(bounds.size))
    }
}

/// Gives the proportional chip a native minimum tap area without changing its artwork size.
struct WalletHomeBalanceChipRowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        let cardWidth = width + WalletHomeBalanceCardMetrics.contentInset * 2
        return CGSize(width: width, height: max(44, WalletHomeBalanceCardMetrics.chipSize(cardWidth: cardWidth).height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
