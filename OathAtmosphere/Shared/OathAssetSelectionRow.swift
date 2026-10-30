import SwiftUI
import OathDatabase
import OathTokenImages

/// All saved-asset pickers use Home's row, including its amount formatting.
struct OathAssetSelectionRow: View {
    let holding: Holding
    let currency: String
    var showsSeparator = false
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        let format = OathAssetAmountFormat(locale: strings.language.locale, selectedCurrencyCode: currency)
        let amounts = OathAssetAmounts(native: holding.nativeDisplayValue, fiat: holding.fiatDisplayValue, currencyCode: currency)
        OathRefinedListRow(title: strings.invariant(holding.name),
            subtitle: strings.invariant(format.nativeSummary(amounts.native, ticker: holding.symbol)),
            value: String(format.fiat(amounts).characters), showsSeparator: showsSeparator,
            emphasizesBalanceSubtitle: true,
            titleBadgeAsset: holding.reference == "native" ? nil : OathImportChain(rawValue: holding.networkID)?.logoAsset) { size in
                OathSendLogo(holding: holding, size: size, showsChainBadge: false)
            }
            .accessibilityLabel([holding.name, OathImportChain(rawValue: holding.networkID)?.name,
                String(format.fiat(amounts).characters), format.native(amounts.native, ticker: holding.symbol)]
                .compactMap { $0 }.joined(separator: ", "))
    }
}

/// One badge treatment for saved holdings and catalog results. The badge always
/// comes from the token's network identity, never its symbol or artwork URL.
struct OathBadgedAssetLogo: View {
    let networkID: String
    let isNative: Bool
    let source: String?
    let symbol: String
    let identity: TokenArtworkIdentity?
    let size: CGFloat
    var showsChainBadge = true
    @Environment(\.layoutDirection) private var layoutDirection

    private var badgeSize: CGFloat { size * 0.4 }
    private var badgeBorder: CGFloat { size * 0.04 }
    private var badgeExtent: CGFloat { badgeSize + badgeBorder * 2 }
    private var badgeOverhang: CGFloat { showsChainBadge ? badgeExtent / 3 : 0 }
    private var badgeOffset: CGFloat { size / 2 - badgeExtent / 6 }
    private var hasBadge: Bool { showsChainBadge && !isNative && OathImportChain(rawValue: networkID) != nil }

    var body: some View {
        Group {
            if isNative, let chain = OathImportChain(rawValue: networkID) {
                OathNetworkLogo(asset: chain.logoAsset, size: size)
            } else {
                OathTokenLogo(source: source, symbol: symbol, size: size, identity: identity)
                    .overlay {
                        if showsChainBadge, let chain = OathImportChain(rawValue: networkID) {
                            OathNetworkLogo(asset: chain.logoAsset, size: badgeSize)
                                .padding(badgeBorder)
                                .background(Color(uiColor: .systemBackground), in:
                                    RoundedRectangle(cornerRadius: badgeSize * TokenArtworkStyle.cornerRadiusFraction + badgeBorder,
                                                     style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: size * 0.025, y: size * 0.0125)
                                // Anchor to the physical bottom-right corner,
                                // including in right-to-left languages.
                                // Two-thirds overlaps the logo; one-third extends outside.
                                .offset(x: badgeOffset, y: badgeOffset)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
        // Reserve horizontal overhang for every asset so labels stay aligned.
        // Padding follows the physical right edge, independently of reading order.
        .padding(.leading, layoutDirection == .rightToLeft ? badgeOverhang : 0)
        .padding(.trailing, layoutDirection == .leftToRight ? badgeOverhang : 0)
        // Plain chain logos have no bottom overhang and stay centered in the row.
        .padding(.bottom, hasBadge ? badgeOverhang : 0)
        .accessibilityHidden(true)
    }
}
