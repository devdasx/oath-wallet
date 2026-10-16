import SwiftUI

struct OathHomeAssetRow: View, Equatable {
    let chain: OathImportChain
    let presentation: OathHomeAssetPresentation
    let balancesHidden: Bool
    var showsSeparator = false
    private var symbol: String { presentation.holding.symbol }
    @Environment(\.oathLocalizer) private var strings

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chain == rhs.chain && lhs.presentation == rhs.presentation &&
        lhs.balancesHidden == rhs.balancesHidden && lhs.showsSeparator == rhs.showsSeparator
    }

    var body: some View {
        OathRefinedListRow(
            title: strings.invariant(presentation.holding.name),
            subtitle: strings.invariant(balancesHidden ? "•••• \(symbol)" : presentation.nativeSummary),
            value: balancesHidden ? "••••" : presentation.fiat,
            showsSeparator: showsSeparator
        ) { size in
            if presentation.holding.reference != "native" {
                OathTokenLogo(source: presentation.holding.logo, symbol: symbol, size: size, identity: presentation.holding.artworkIdentity)
                    .overlay(alignment: .bottomTrailing) {
                        OathNetworkLogo(asset: chain.logoAsset, size: size * 0.325)
                            .padding(2)
                            .background(Color(uiColor: OathSurfaceColors.canvas), in: Circle())
                            .alignmentGuide(.trailing) { $0[.trailing] - 3 }
                            .alignmentGuide(.bottom) { $0[.bottom] - 2 }
                    }
            } else {
                OathNetworkLogo(asset: chain.logoAsset, size: size)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let identity = "\(presentation.holding.name), \(chain.name)"
        if balancesHidden { return "\(identity), \(strings.text(.balanceHidden))" }
        return "\(identity), \(presentation.fiat), \(presentation.nativeFull)"
    }
}
