import Foundation
import SwiftUI

struct AssetNetworkSelectorOption: Identifiable, Hashable, Sendable {
    let id: String
    let localizedName: String
    let blockchain: WalletBlockchain
    /// Set for a family chip (bStocks…): a curated group of tokens on
    /// `blockchain` that gets its own section next to the networks.
    var family: AssetFamily? = nil

    var officialLogoAssetName: String {
        family?.logoAssetName ?? blockchain.officialLogoAssetName
    }

    /// Every supported network, in catalog order. This is the list the rest
    /// of the app enumerates as "the networks"; family chips are not in it.
    static let allSupported: [AssetNetworkSelectorOption] = {
        let bitcoin = [BitcoinFamilyChain.bitcoin].map {
            AssetNetworkSelectorOption(
                id: $0.networkID,
                localizedName: $0.name,
                blockchain: $0.blockchain
            )
        }
        let remaining = ReceiveNetworkCatalog.all.map {
            AssetNetworkSelectorOption(
                id: $0.id,
                localizedName: $0.localizedName,
                blockchain: $0.blockchain
            )
        }
        let trailingBitcoinFamily = [
            BitcoinFamilyChain.bitcoinCash,
            .litecoin,
            .dogecoin
        ].map {
            AssetNetworkSelectorOption(
                id: $0.networkID,
                localizedName: $0.name,
                blockchain: $0.blockchain
            )
        }
        return bitcoin + remaining + trailingBitcoinFamily
    }()

    /// The chips of the asset pickers: every network plus, right after the
    /// network it lives on, each asset family (bStocks…).
    static let allSelectable: [AssetNetworkSelectorOption] =
        allSupported.flatMap { network in
            [network] + AssetFamily.allCases
                .filter { $0.networkID == network.id }
                .map { family in
                    AssetNetworkSelectorOption(
                        id: family.selectorID,
                        localizedName: family.localizedName,
                        blockchain: family.blockchain,
                        family: family
                    )
                }
        }

    private static let networkIDByBlockchain = Dictionary(
        uniqueKeysWithValues: allSupported.map {
            ($0.blockchain, $0.id)
        }
    )

    private static let blockchainByNetworkID = Dictionary(
        uniqueKeysWithValues: allSelectable.map {
            ($0.id, $0.blockchain)
        }
    )

    static func networkID(
        for blockchain: WalletBlockchain?
    ) -> String? {
        guard let blockchain else { return nil }
        return networkIDByBlockchain[blockchain]
    }

    static func blockchain(
        for networkID: String?
    ) -> WalletBlockchain? {
        guard let networkID else { return nil }
        return blockchainByNetworkID[networkID]
    }

    /// The family a selector identifier stands for, or nil for a network.
    static func family(for networkID: String?) -> AssetFamily? {
        AssetFamily.selectorFamily(for: networkID)
    }

    /// True when `asset` belongs under the chip `networkID`: its chain for a
    /// network chip; its family, or the chain's native coin that pays the
    /// gas for the family, for a family chip. A nil identifier means every
    /// asset.
    static func includes(
        _ asset: WalletAsset,
        in networkID: String?
    ) -> Bool {
        guard let networkID else { return true }
        guard let blockchain = blockchain(for: networkID),
              asset.network == blockchain
        else {
            return false
        }
        guard let family = family(for: networkID) else { return true }
        if AssetIdentityKey.contractAddress(from: asset.id) == nil {
            return true
        }
        return asset.family == family
    }
}

struct WalletNetworkSelectionOrdering: Sendable {
    static let catalogOrder = WalletNetworkSelectionOrdering()

    private let localCurrencyValueByNetworkID: [String: Decimal]
    private let transactionCountByNetworkID: [String: Int]

    init(
        walletAssets: [WalletAsset] = [],
        transactions: [WalletTransaction] = [],
        currencyContext: WalletCurrencyContext? = nil
    ) {
        self.init(
            localCurrencyValues: walletAssets.flatMap { asset -> [(String, Decimal)] in
                guard
                    let networkID = Self.networkID(
                        for: asset.network
                    ),
                    asset.fiatValue > 0
                else {
                    return []
                }
                // A family chip earns the value of its members as well.
                return [(networkID, asset.fiatValue)]
                    + (asset.family.map { [($0.selectorID, asset.fiatValue)] } ?? [])
            },
            transactions: transactions
        )
    }

    init(
        sendChoices: [SendAssetChoice],
        transactions: [WalletTransaction],
        currencyContext: WalletCurrencyContext? = nil
    ) {
        self.init(
            localCurrencyValues: sendChoices.flatMap { choice -> [(String, Decimal)] in
                guard choice.fiatValue > 0 else { return [] }
                return [(choice.networkID, choice.fiatValue)]
                    + (choice.family.map { [($0.selectorID, choice.fiatValue)] } ?? [])
            },
            transactions: transactions
        )
    }

    init(
        localCurrencyValueByNetworkID: [String: Decimal],
        transactionCountByNetworkID: [String: Int]
    ) {
        self.localCurrencyValueByNetworkID = Self.canonicalizedValues(
            localCurrencyValueByNetworkID
        )
        self.transactionCountByNetworkID = Self.canonicalizedCounts(
            transactionCountByNetworkID
        )
    }

    func ordered<Element>(
        _ elements: [Element],
        networkID: (Element) -> String
    ) -> [Element] {
        elements.enumerated().sorted { lhs, rhs in
            let lhsMetrics = metrics(
                for: networkID(lhs.element),
                originalIndex: lhs.offset
            )
            let rhsMetrics = metrics(
                for: networkID(rhs.element),
                originalIndex: rhs.offset
            )

            if lhsMetrics.tier != rhsMetrics.tier {
                return lhsMetrics.tier < rhsMetrics.tier
            }

            switch lhsMetrics.tier {
            case 0:
                if lhsMetrics.localCurrencyValue
                    != rhsMetrics.localCurrencyValue {
                    return lhsMetrics.localCurrencyValue
                        > rhsMetrics.localCurrencyValue
                }
                if lhsMetrics.transactionCount
                    != rhsMetrics.transactionCount {
                    return lhsMetrics.transactionCount
                        > rhsMetrics.transactionCount
                }
            case 1:
                if lhsMetrics.transactionCount
                    != rhsMetrics.transactionCount {
                    return lhsMetrics.transactionCount
                        > rhsMetrics.transactionCount
                }
            default:
                break
            }

            return lhsMetrics.originalIndex < rhsMetrics.originalIndex
        }
        .map(\.element)
    }

    func ordered(
        _ options: [AssetNetworkSelectorOption]
    ) -> [AssetNetworkSelectorOption] {
        ordered(options, networkID: \.id)
    }

    static func canonicalNetworkID(
        _ identifier: String?
    ) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return canonicalNetworkIDsByAlias[normalized] ?? normalized
    }

    private init(
        localCurrencyValues: [(String, Decimal)],
        transactions: [WalletTransaction]
    ) {
        var values: [String: Decimal] = [:]
        for (identifier, usdValue) in localCurrencyValues {
            guard
                usdValue > 0,
                let networkID = Self.canonicalNetworkID(identifier)
            else {
                continue
            }
            // Every network value is converted by the same selected-currency
            // rate. Multiplying here cannot change ordering and needlessly
            // repeats Decimal arithmetic whenever a selector re-renders.
            values[networkID, default: 0] += usdValue
        }

        var counts: [String: Int] = [:]
        for transaction in transactions {
            guard
                let networkID = Self.canonicalNetworkID(
                    transaction.metadata.blockchainIdentifier
                )
            else {
                continue
            }
            let existing = counts[networkID, default: 0]
            if existing < Int.max {
                counts[networkID] = existing + 1
            }
        }

        localCurrencyValueByNetworkID = values
        transactionCountByNetworkID = counts
    }

    private func metrics(
        for identifier: String,
        originalIndex: Int
    ) -> Metrics {
        let networkID = Self.canonicalNetworkID(identifier) ?? identifier
        let localCurrencyValue =
            localCurrencyValueByNetworkID[networkID] ?? 0
        let transactionCount =
            transactionCountByNetworkID[networkID] ?? 0
        let tier: Int
        if localCurrencyValue > 0 {
            tier = 0
        } else if transactionCount > 0 {
            tier = 1
        } else {
            tier = 2
        }
        return Metrics(
            tier: tier,
            localCurrencyValue: localCurrencyValue,
            transactionCount: transactionCount,
            originalIndex: originalIndex
        )
    }

    private static func networkID(
        for blockchain: WalletBlockchain?
    ) -> String? {
        guard let blockchain else { return nil }
        return AssetNetworkSelectorOption.networkID(for: blockchain)
            ?? canonicalNetworkID(blockchain.rawValue)
    }

    private static func canonicalizedValues(
        _ values: [String: Decimal]
    ) -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        for (identifier, value) in values where value > 0 {
            guard let networkID = canonicalNetworkID(identifier) else {
                continue
            }
            result[networkID, default: 0] += value
        }
        return result
    }

    private static func canonicalizedCounts(
        _ counts: [String: Int]
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for (identifier, count) in counts where count > 0 {
            guard let networkID = canonicalNetworkID(identifier) else {
                continue
            }
            let existing = result[networkID, default: 0]
            let sum = existing.addingReportingOverflow(count)
            result[networkID] = sum.overflow ? Int.max : sum.partialValue
        }
        return result
    }

    private static let canonicalNetworkIDsByAlias: [String: String] = {
        var result: [String: String] = [:]
        for option in AssetNetworkSelectorOption.allSupported {
            result[option.id.lowercased()] = option.id
            result[option.blockchain.rawValue.lowercased()] = option.id
        }
        let aliases = [
            "btc": "bitcoin",
            "bch": "bitcoin_cash",
            "bitcoincash": "bitcoin_cash",
            "ltc": "litecoin",
            "doge": "dogecoin",
            "trx": "tron",
            "sol": "solana",
            "the_open_network": "ton",
            "ethereum": "eth",
            "bnb": "bsc",
            "bnb_smart_chain": "bsc",
            "matic": "polygon",
            "avax": "avalanche",
            "x_layer": "xlayer",
            "x-layer": "xlayer"
        ]
        for (alias, networkID) in aliases {
            result[alias] = networkID
        }
        return result
    }()

    private struct Metrics {
        let tier: Int
        let localCurrencyValue: Decimal
        let transactionCount: Int
        let originalIndex: Int
    }
}

enum AssetNetworkSelectorPresentation {
    case filled
    case liquidGlass
}

struct AssetNetworkSelector: View {
    private let orderedOptions: [AssetNetworkSelectorOption]
    @Binding var selectedNetworkID: String?
    private let presentation: AssetNetworkSelectorPresentation
    private let onSelectionChanged: ((String?, String?) -> Void)?

    init(
        options: [AssetNetworkSelectorOption],
        selectedNetworkID: Binding<String?>,
        ordering: WalletNetworkSelectionOrdering = .catalogOrder,
        presentation: AssetNetworkSelectorPresentation = .filled,
        onSelectionChanged: ((String?, String?) -> Void)? = nil
    ) {
        orderedOptions = ordering.ordered(options)
        _selectedNetworkID = selectedNetworkID
        self.presentation = presentation
        self.onSelectionChanged = onSelectionChanged
    }

    var body: some View {
        ScrollView(.horizontal) {
            switch presentation {
            case .filled:
                selectionControls
            case .liquidGlass:
                WalletGlassEffectContainer(spacing: 8) {
                    selectionControls
                }
            }
        }
        // Let the eager row supply its ideal height rather than accepting the
        // safe-area bar's full vertical proposal or imposing a chip height.
        .fixedSize(horizontal: false, vertical: true)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollClipDisabled(presentation == .liquidGlass)
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("receive.network_filter.title"))
    }

    @ViewBuilder
    private var selectionControls: some View {
        HStack(spacing: 8) {
            selectionButton(
                id: nil,
                title: WalletLocalization.string(
                    "receive.network_filter.all"
                ),
                logoAssetName: nil
            )

            ForEach(orderedOptions) { option in
                selectionButton(
                    id: option.id,
                    title: option.localizedName,
                    logoAssetName: option.officialLogoAssetName
                )
            }
        }
    }

    @ViewBuilder
    private func selectionButton(
        id: String?,
        title: String,
        logoAssetName: String?
    ) -> some View {
        let isSelected = selectedNetworkID == id

        switch presentation {
        case .filled:
            selectionControl(
                id: id,
                title: title,
                logoAssetName: logoAssetName,
                isSelected: isSelected
            )
            .buttonStyle(.borderedProminent)
            .tint(isSelected ? WalletTheme.accent : WalletTheme.mutedSecondaryFill)
            .buttonBorderShape(.capsule)
        case .liquidGlass:
            if isSelected {
                selectionControl(
                    id: id,
                    title: title,
                    logoAssetName: logoAssetName,
                    isSelected: true
                )
                .walletAdaptiveGlassButtonStyle(tint: WalletTheme.accent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            } else {
                selectionControl(
                    id: id,
                    title: title,
                    logoAssetName: logoAssetName,
                    isSelected: false
                )
                .walletAdaptiveGlassButtonStyle(tint: nil)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        }
    }

    private func selectionControl(
        id: String?,
        title: String,
        logoAssetName: String?,
        isSelected: Bool
    ) -> some View {
        Button(action: UniHaptic.action {
            select(id)
        }) {
            selectionLabel(
                title: title,
                logoAssetName: logoAssetName,
                isSelected: isSelected
            )
        }
        .accessibilityValue(
            Text(
                LocalizedStringKey(
                    isSelected
                        ? "selection.selected"
                        : "selection.not_selected"
                )
            )
        )
    }

    private func selectionLabel(
        title: String,
        logoAssetName: String?,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if let logoAssetName {
                OfficialNetworkLogoView(
                    assetName: logoAssetName,
                    size: 22
                )
            }

            Text(verbatim: title)
                .font(
                    .subheadline.weight(
                        isSelected ? .semibold : .regular
                    )
                )
                .foregroundStyle(
                    isSelected
                        ? WalletTheme.onAccentLabel
                        : WalletTheme.primaryLabel
                )
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
    }

    private func select(_ networkID: String?) {
        guard selectedNetworkID != networkID else { return }
        let previousNetworkID = selectedNetworkID
        onSelectionChanged?(previousNetworkID, networkID)
        UniHaptic.play(.selection)
        selectedNetworkID = networkID
    }
}

private struct AssetNetworkAppBarModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var bottomClearance: CGFloat = 8
    let isPresented: Bool
    let options: [AssetNetworkSelectorOption]
    @Binding var selectedNetworkID: String?
    let ordering: WalletNetworkSelectionOrdering
    let onSelectionChanged: ((String?, String?) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPresented {
            content
                .walletSafeAreaBar(edge: .top, spacing: 0) {
                    AssetNetworkSelector(
                        options: options,
                        selectedNetworkID: $selectedNetworkID,
                        ordering: ordering,
                        presentation: .liquidGlass,
                        onSelectionChanged: onSelectionChanged
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, bottomClearance)
                }
        } else {
            content
        }
    }
}

extension View {
    func assetNetworkAppBar(
        isPresented: Bool,
        options: [AssetNetworkSelectorOption],
        selectedNetworkID: Binding<String?>,
        ordering: WalletNetworkSelectionOrdering = .catalogOrder,
        onSelectionChanged: ((String?, String?) -> Void)? = nil
    ) -> some View {
        modifier(
            AssetNetworkAppBarModifier(
                isPresented: isPresented,
                options: options,
                selectedNetworkID: selectedNetworkID,
                ordering: ordering,
                onSelectionChanged: onSelectionChanged
            )
        )
    }
}

struct OfficialNetworkLogoView: View {
    let assetName: String
    let size: CGFloat

    var body: some View {
        Image(assetName)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
