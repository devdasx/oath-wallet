import Foundation

struct ReceiveNetwork: Identifiable, Hashable, Sendable {
    let id: String
    let nameKey: String
    let symbol: String
    let chainID: Int
    let blockchain: WalletBlockchain

    var localizedName: String {
        WalletLocalization.string(nameKey)
    }

    /// Arc pays gas in USDC, so its native asset is the stablecoin rather
    /// than a coin named after the chain. Every other network's native asset
    /// carries the network's own name.
    var nativeAssetIsStablecoin: Bool {
        id == "arc"
    }

    var nativeAssetName: String {
        nativeAssetIsStablecoin ? symbol : localizedName
    }

    var logoSource: AssetLogoSource {
        .network(blockchain: blockchain)
    }
}

enum ReceiveNetworkCatalog {
    static let all: [ReceiveNetwork] = [
        ReceiveNetwork(
            id: AptosConstants.networkID,
            nameKey: "network.aptos.name",
            symbol: AptosConstants.nativeSymbol,
            chainID: AptosConstants.databaseChainID,
            blockchain: .aptos
        ),
        ReceiveNetwork(
            id: StellarConstants.networkID,
            nameKey: "network.stellar.name",
            symbol: StellarConstants.nativeSymbol,
            chainID: StellarConstants.databaseChainID,
            blockchain: .stellar
        ),
        ReceiveNetwork(
            id: "eth",
            nameKey: "network.ethereum",
            symbol: "ETH",
            chainID: 1,
            blockchain: .ethereum
        ),
        ReceiveNetwork(
            id: "tron",
            nameKey: "network.tron.name",
            symbol: "TRX",
            chainID: -195,
            blockchain: .tron
        ),
        ReceiveNetwork(
            id: "solana",
            nameKey: "network.solana.name",
            symbol: "SOL",
            chainID: -501,
            blockchain: .solana
        ),
        ReceiveNetwork(
            id: "ton",
            nameKey: "network.ton.name",
            symbol: TONConstants.nativeSymbol,
            chainID: TONConstants.databaseChainID,
            blockchain: .ton
        ),
        ReceiveNetwork(
            id: SuiConstants.networkID,
            nameKey: "network.sui.name",
            symbol: SuiConstants.nativeSymbol,
            chainID: SuiConstants.databaseChainID,
            blockchain: .sui
        ),
        ReceiveNetwork(
            id: NEARConstants.networkID,
            nameKey: "network.near.name",
            symbol: NEARConstants.nativeSymbol,
            chainID: NEARConstants.databaseChainID,
            blockchain: .near
        ),
        ReceiveNetwork(
            id: XRPConstants.networkID,
            nameKey: "network.xrp.name",
            symbol: XRPConstants.nativeSymbol,
            chainID: XRPConstants.databaseChainID,
            blockchain: .xrp
        ),
        ReceiveNetwork(
            id: "bsc",
            nameKey: "network.bnb_smart_chain",
            symbol: "BNB",
            chainID: 56,
            blockchain: .smartchain
        ),
        ReceiveNetwork(
            id: "arbitrum",
            nameKey: "network.arbitrum",
            symbol: "ETH",
            chainID: 42_161,
            blockchain: .arbitrum
        ),
        ReceiveNetwork(
            id: "base",
            nameKey: "network.base",
            symbol: "ETH",
            chainID: 8_453,
            blockchain: .base
        ),
        ReceiveNetwork(
            id: "polygon",
            nameKey: "network.polygon",
            symbol: "POL",
            chainID: 137,
            blockchain: .polygon
        ),
        ReceiveNetwork(
            id: "optimism",
            nameKey: "network.optimism",
            symbol: "ETH",
            chainID: 10,
            blockchain: .optimism
        ),
        ReceiveNetwork(
            id: "avalanche",
            nameKey: "network.avalanche",
            symbol: "AVAX",
            chainID: 43_114,
            blockchain: .avalanchec
        ),
        ReceiveNetwork(
            id: "gnosis",
            nameKey: "network.gnosis",
            symbol: "XDAI",
            chainID: 100,
            blockchain: .xdai
        ),
        ReceiveNetwork(
            id: "linea",
            nameKey: "network.linea",
            symbol: "ETH",
            chainID: 59_144,
            blockchain: .linea
        ),
        ReceiveNetwork(
            id: "scroll",
            nameKey: "network.scroll",
            symbol: "ETH",
            chainID: 534_352,
            blockchain: .scroll
        ),
        ReceiveNetwork(
            id: "taiko",
            nameKey: "network.taiko",
            symbol: "ETH",
            chainID: 167_000,
            blockchain: .taiko
        ),
        ReceiveNetwork(
            id: "telos",
            nameKey: "network.telos",
            symbol: "TLOS",
            chainID: 40,
            blockchain: .telos
        ),
        ReceiveNetwork(
            id: "xlayer",
            nameKey: "network.x_layer",
            symbol: "OKB",
            chainID: 196,
            blockchain: .xlayer
        ),
        ReceiveNetwork(
            id: "arc",
            nameKey: "network.arc",
            symbol: "USDC",
            chainID: 5_042,
            blockchain: .arc
        )
    ]

    private static let networksByID = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    private static let networksByBlockchain = Dictionary(
        uniqueKeysWithValues: all.map {
            ($0.blockchain, $0)
        }
    )

    private static let bitcoinFamilyNetworks: [ReceiveNetwork] =
        BitcoinFamilyChain.allCases.compactMap { chain in
            guard let chainID = Int(exactly: chain.databaseChainID) else {
                return nil
            }
            return ReceiveNetwork(
                id: chain.networkID,
                nameKey: chain.nameKey,
                symbol: chain.symbol,
                chainID: chainID,
                blockchain: chain.blockchain
            )
        }

    private static let catalogNetworksByID = Dictionary(
        uniqueKeysWithValues: (all + bitcoinFamilyNetworks).map {
            ($0.id, $0)
        }
    )

    private static let catalogNetworksByBlockchain = Dictionary(
        uniqueKeysWithValues: (all + bitcoinFamilyNetworks).map {
            ($0.blockchain, $0)
        }
    )

    /// The ERC-20 interface that mirrors a network's native balance. Arc's
    /// USDC precompile is the only one: activity on it is native activity.
    static func nativeAliasContract(for networkID: String) -> String? {
        networkID == ArcNetworkConstants.networkID
            ? ArcNetworkConstants.usdcInterfaceContract
            : nil
    }

    static func network(for identifier: String) -> ReceiveNetwork? {
        networksByID[identifier]
    }

    static func network(
        for blockchain: WalletBlockchain
    ) -> ReceiveNetwork? {
        networksByBlockchain[blockchain]
    }

    /// Resolves every mainnet that may own an asset-catalog row. `all`
    /// remains the account/network-selection catalog, while Bitcoin-family
    /// networks participate in the remotely sourced asset catalog as well.
    static func catalogNetwork(for identifier: String) -> ReceiveNetwork? {
        catalogNetworksByID[identifier]
    }

    /// Every network identifier this build can install from the remote
    /// catalog. Sent with each catalog read so the service never returns a
    /// network this build would reject.
    static let catalogNetworkIdentifiers: [String] =
        catalogNetworksByID.keys.sorted()

    static func catalogNetwork(
        for blockchain: WalletBlockchain
    ) -> ReceiveNetwork? {
        catalogNetworksByBlockchain[blockchain]
    }
}

struct ReceiveTokenVariant: Codable, Hashable, Sendable {
    let networkID: String
    let contractAddress: String?
    let decimals: Int
    let networkRank: Int?
    let logoURL: String?
    let marketDataID: String?
    let isVerified: Bool
    /// The curated family this variant belongs to (bStocks…), if any.
    let family: AssetFamily?

    init(
        networkID: String,
        contractAddress: String?,
        decimals: Int,
        networkRank: Int?,
        logoURL: String?,
        marketDataID: String? = nil,
        isVerified: Bool = true,
        family: AssetFamily? = nil
    ) {
        self.networkID = networkID
        self.contractAddress = contractAddress
        self.decimals = decimals
        self.networkRank = networkRank
        self.logoURL = logoURL
        self.marketDataID = marketDataID
        self.isVerified = isVerified
        self.family = family
    }

    var familyLogoSource: AssetLogoSource? {
        family?.logoSource
    }

    var network: ReceiveNetwork? {
        ReceiveNetworkCatalog.catalogNetwork(for: networkID)
    }

    var assetIdentity: String {
        AssetIdentityKey.make(
            networkID: networkID,
            contractAddress: contractAddress
        )
    }

    var logoSource: AssetLogoSource {
        guard let network else { return .unavailable }
        guard let contractAddress else {
            return .nativeCoin(blockchain: network.blockchain)
        }
        return .catalogToken(
            blockchain: network.blockchain,
            contractAddress: contractAddress,
            logoURL: logoURL
        )
    }
}

struct ReceiveToken: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let rank: Int
    let isStablecoin: Bool?
    let variants: [ReceiveTokenVariant]

    static func nativeAsset(for network: ReceiveNetwork) -> ReceiveToken {
        let decimals: Int
        switch network.id {
        case "tron", "xrp": decimals = 6
        case StellarConstants.networkID:
            decimals = StellarConstants.decimals
        case "solana", "ton", "sui": decimals = 9
        case AptosConstants.networkID: decimals = AptosConstants.decimals
        case "near": decimals = NEARConstants.decimals
        default: decimals = 18
        }
        return ReceiveToken(
            id: "native-\(network.id)",
            name: network.nativeAssetName,
            symbol: network.symbol,
            rank: .min,
            isStablecoin: network.nativeAssetIsStablecoin,
            variants: [
                ReceiveTokenVariant(
                    networkID: network.id,
                    contractAddress: nil,
                    decimals: decimals,
                    networkRank: 0,
                    logoURL: nil
                )
            ]
        )
    }
}

enum ReceiveAssetCatalog {
    /// The curated family of an asset in the installed catalog, if any.
    static func family(forAssetIdentity identity: String) -> AssetFamily? {
        ReceiveAssetCatalogRuntime.snapshot.familiesByAssetIdentity[
            AssetIdentityKey.canonical(identity)
        ]
    }

    static let defaultVisibleTokenLimit = 150

    private struct Index {
        let tokens: [ReceiveToken]
        let walletAssets: [WalletAsset]
        let tokensByNetworkID: [String: [ReceiveToken]]
        let strengthByAssetIdentity: [String: AssetStrength]
        let variantByAssetIdentity: [String: ReceiveTokenVariant]
        let selectionByAssetIdentity: [String: ReceiveVariantSelection]

        init(tokens: [ReceiveToken]) {
            self.tokens = tokens

            var assets: [WalletAsset] = []
            var tokensByNetworkID: [String: [ReceiveToken]] = [:]
            var strengths: [String: AssetStrength] = [:]
            var variants: [String: ReceiveTokenVariant] = [:]
            var selections: [String: ReceiveVariantSelection] = [:]

            for token in tokens {
                for variant in token.variants {
                    guard let network = variant.network else { continue }
                    let identity = AssetIdentityKey.canonical(
                        variant.assetIdentity
                    )
                    assets.append(
                        WalletAsset(
                            id: identity,
                            name: token.name,
                            symbol: token.symbol,
                            logoSource: variant.logoSource,
                            network: network.blockchain,
                            balance: .zero,
                            fiatValue: .zero,
                            decimals: variant.decimals,
                            isVerified: variant.isVerified
                        )
                    )
                    tokensByNetworkID[variant.networkID, default: []]
                        .append(token)

                    let candidate = AssetStrength(
                        globalRank: token.rank,
                        networkRank: variant.networkRank ?? Int.max,
                        isNative: variant.contractAddress == nil
                    )
                    if let existing = strengths[identity] {
                        if candidate.globalRank < existing.globalRank
                            || (
                                candidate.globalRank
                                    == existing.globalRank
                                    && candidate.networkRank
                                        < existing.networkRank
                            ) {
                            strengths[identity] = candidate
                        }
                    } else {
                        strengths[identity] = candidate
                    }
                    variants[identity] = variants[identity] ?? variant
                    selections[identity] = selections[identity]
                        ?? ReceiveVariantSelection(
                            token: token,
                            variant: variant
                        )
                }
            }

            for networkID in tokensByNetworkID.keys {
                tokensByNetworkID[networkID]?.sort { lhs, rhs in
                    let lhsRank = lhs.variants.first {
                        $0.networkID == networkID
                    }?.networkRank ?? Int.max
                    let rhsRank = rhs.variants.first {
                        $0.networkID == networkID
                    }?.networkRank ?? Int.max
                    if lhsRank != rhsRank { return lhsRank < rhsRank }
                    if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                    return lhs.id < rhs.id
                }
            }

            walletAssets = assets
            self.tokensByNetworkID = tokensByNetworkID
            strengthByAssetIdentity = strengths
            variantByAssetIdentity = variants
            selectionByAssetIdentity = selections
        }
    }

    private static let indexLock = NSLock()
    nonisolated(unsafe) private static var cachedIndex:
        (generation: UInt64, value: Index)?

    private static var index: Index {
        let snapshot = ReceiveAssetCatalogRuntime.snapshot
        return indexLock.withLock {
            if let cachedIndex,
               cachedIndex.generation == snapshot.generation {
                return cachedIndex.value
            }
            let value = Index(tokens: snapshot.tokens)
            cachedIndex = (snapshot.generation, value)
            return value
        }
    }

    static var tokens: [ReceiveToken] {
        index.tokens
    }

    static var walletAssets: [WalletAsset] {
        index.walletAssets
    }

    struct AssetStrength: Sendable {
        let globalRank: Int
        let networkRank: Int
        let isNative: Bool
    }

    static func selection(
        assetIdentity: String
    ) -> ReceiveVariantSelection? {
        index.selectionByAssetIdentity[
            AssetIdentityKey.canonical(assetIdentity)
        ]
    }

    static func variant(
        networkID: String,
        contractAddress: String
    ) -> ReceiveTokenVariant? {
        index.variantByAssetIdentity[
            AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contractAddress
            )
        ]
    }

    static func marketDataID(for assetIdentity: String) -> String? {
        index.variantByAssetIdentity[
            AssetIdentityKey.canonical(assetIdentity)
        ]?.marketDataID
    }

    static func strength(for asset: WalletAsset) -> AssetStrength {
        if let strength = index.strengthByAssetIdentity[
            AssetIdentityKey.canonical(asset.id)
        ] {
            return strength
        }
        return AssetStrength(
            globalRank: Int.max,
            networkRank: Int.max,
            isNative: {
                guard case .nativeCoin = asset.logoSource else {
                    return false
                }
                return true
            }()
        )
    }

    static func tokens(for networkID: String?) -> [ReceiveToken] {
        guard let networkID else { return tokens }
        return index.tokensByNetworkID[networkID] ?? []
    }

    static func defaultTokens(for networkID: String?) -> [ReceiveToken] {
        Array(
            tokens(for: networkID)
                .prefix(defaultVisibleTokenLimit)
        )
    }
}

enum WalletAssetCatalogOrdering {
    enum SectionKind: Int, CaseIterable, Identifiable, Sendable {
        case holdings
        case popular
        case allCrypto

        var id: Int { rawValue }

        var titleKey: String {
            switch self {
            case .holdings:
                "wallet.assets.section.holdings"
            case .popular:
                "wallet.assets.section.popular"
            case .allCrypto:
                "wallet.assets.section.all_crypto"
            }
        }
    }

    struct Section: Identifiable {
        let kind: SectionKind
        let assets: [WalletAsset]

        var id: Int { kind.id }
    }

    private struct PopularIdentity: Hashable {
        let symbol: String
        let network: WalletBlockchain
    }

    private static let popularOrder: [PopularIdentity] = [
        PopularIdentity(symbol: "BTC", network: .bitcoin),
        PopularIdentity(symbol: "ETH", network: .ethereum),
        PopularIdentity(symbol: "BNB", network: .smartchain),
        PopularIdentity(symbol: "TRX", network: .tron),
        PopularIdentity(symbol: TONConstants.nativeSymbol, network: .ton),
        PopularIdentity(symbol: "USDT", network: .ethereum),
        PopularIdentity(symbol: "USDC", network: .base),
        PopularIdentity(symbol: "LINK", network: .polygon),
        PopularIdentity(symbol: "DAI", network: .ethereum),
        PopularIdentity(symbol: "USDS", network: .ethereum),
        PopularIdentity(symbol: "SHIB", network: .smartchain)
    ]

    private static let popularIdentityRank: [PopularIdentity: Int] = Dictionary(
        uniqueKeysWithValues: popularOrder.enumerated().map { index, value in
            (value, index)
        }
    )

    private static let popularRankLock = NSLock()
    nonisolated(unsafe) private static var cachedPopularAssetRank:
        (generation: UInt64, value: [String: Int])?

    private static var popularAssetRank: [String: Int] {
        let generation = ReceiveAssetCatalogRuntime.snapshot.generation
        return popularRankLock.withLock {
            if let cachedPopularAssetRank,
               cachedPopularAssetRank.generation == generation {
                return cachedPopularAssetRank.value
            }
            let value = buildPopularAssetRank()
            cachedPopularAssetRank = (generation, value)
            return value
        }
    }

    private static func buildPopularAssetRank() -> [String: Int] {
        var result: [String: Int] = [:]
        for identity in popularOrder {
            guard
                let position = popularIdentityRank[identity],
                let networkID = ReceiveNetworkCatalog.catalogNetwork(
                    for: identity.network
                )?.id
            else {
                continue
            }

            let candidates = ReceiveAssetCatalog.tokens.flatMap { token in
                token.variants.compactMap { variant
                    -> (String, Int, Int)? in
                    guard
                        token.symbol.caseInsensitiveCompare(
                            identity.symbol
                        ) == .orderedSame,
                        variant.networkID == networkID
                    else {
                        return nil
                    }
                    return (
                        AssetIdentityKey.canonical(
                            variant.assetIdentity
                        ),
                        token.rank,
                        variant.networkRank ?? Int.max
                    )
                }
            }
            guard let strongest = candidates.min(by: { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 < rhs.1
                }
                return lhs.2 < rhs.2
            }) else {
                continue
            }
            result[strongest.0] = position
        }
        return result
    }

    private static let nativeStrengthOrder: [
        WalletBlockchain: Int
    ] = [
        .bitcoin: 0,
        .ethereum: 2,
        .sui: 3,
        .ton: 4,
        .solana: 5,
        .smartchain: 6,
        .tron: 7,
        .dogecoin: 8,
        .bitcoincash: 9,
        .litecoin: 10,
        .polygon: 11,
        .avalanchec: 12,
        .arbitrum: 13,
        .base: 14,
        .optimism: 15,
        .xdai: 16,
        .scroll: 17,
        .linea: 18,
        .taiko: 19,
        .telos: 20,
        .xlayer: 21,
        .arc: 22
    ]

    static func sections(
        from assets: [WalletAsset],
        selectedNetwork: WalletBlockchain?
    ) -> [Section] {
        let filtered = selectedNetwork.map { network in
            assets.filter { $0.network == network }
        } ?? assets
        let sorted = filtered.sorted(by: precedes)

        return SectionKind.allCases.compactMap { kind in
            let matching = sorted.filter { sectionKind(for: $0) == kind }
            guard !matching.isEmpty else { return nil }
            return Section(kind: kind, assets: matching)
        }
    }

    static func sorted(
        _ assets: [WalletAsset],
        selectedNetwork: WalletBlockchain?
    ) -> [WalletAsset] {
        sections(
            from: assets,
            selectedNetwork: selectedNetwork
        )
        .flatMap(\.assets)
    }

    private static func sectionKind(
        for asset: WalletAsset
    ) -> SectionKind {
        if asset.balance != .zero || asset.isPinned {
            return .holdings
        }
        if popularPosition(for: asset) != nil {
            return .popular
        }
        return .allCrypto
    }

    private static func precedes(
        _ lhs: WalletAsset,
        _ rhs: WalletAsset
    ) -> Bool {
        let lhsSection = sectionKind(for: lhs)
        let rhsSection = sectionKind(for: rhs)
        if lhsSection != rhsSection {
            return lhsSection.rawValue < rhsSection.rawValue
        }

        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }

        if lhsSection == .holdings, lhs.fiatValue != rhs.fiatValue {
            return lhs.fiatValue > rhs.fiatValue
        }

        let lhsPopular = popularPosition(for: lhs)
        let rhsPopular = popularPosition(for: rhs)
        if lhsPopular != rhsPopular {
            return (lhsPopular ?? Int.max) < (rhsPopular ?? Int.max)
        }

        let lhsStrength = ReceiveAssetCatalog.strength(for: lhs)
        let rhsStrength = ReceiveAssetCatalog.strength(for: rhs)
        if lhsStrength.isNative != rhsStrength.isNative {
            return lhsStrength.isNative
        }
        if lhsStrength.isNative {
            let lhsNativeRank = lhs.network.flatMap {
                nativeStrengthOrder[$0]
            } ?? Int.max
            let rhsNativeRank = rhs.network.flatMap {
                nativeStrengthOrder[$0]
            } ?? Int.max
            if lhsNativeRank != rhsNativeRank {
                return lhsNativeRank < rhsNativeRank
            }
        }
        if lhsStrength.globalRank != rhsStrength.globalRank {
            return lhsStrength.globalRank < rhsStrength.globalRank
        }
        if lhsStrength.networkRank != rhsStrength.networkRank {
            return lhsStrength.networkRank < rhsStrength.networkRank
        }
        if lhs.symbol != rhs.symbol {
            return lhs.symbol.localizedStandardCompare(rhs.symbol)
                == .orderedAscending
        }
        return lhs.name.localizedStandardCompare(rhs.name)
            == .orderedAscending
    }

    private static func popularPosition(
        for asset: WalletAsset
    ) -> Int? {
        guard let network = asset.network else { return nil }
        let identity = PopularIdentity(
            symbol: asset.symbol.uppercased(),
            network: network
        )
        guard let position = popularIdentityRank[identity] else {
            return nil
        }
        if case .nativeCoin = asset.logoSource {
            return position
        }
        return popularAssetRank[AssetIdentityKey.canonical(asset.id)]
    }
}

struct WalletAssetSelectionGroup: Identifiable, Sendable {
    let id: String
    let token: ReceiveToken?
    let name: String
    let symbol: String
    let assets: [WalletAsset]

    var logoSource: AssetLogoSource {
        token?.variants.first?.logoSource
            ?? assets.first?.logoSource
            ?? .unavailable
    }

    var networkLogoSource: AssetLogoSource? {
        assets.first?.networkLogoSource
    }

    var familyLogoSource: AssetLogoSource? {
        assets.first?.familyLogoSource
            ?? token?.variants.first?.familyLogoSource
    }

    var balance: Decimal {
        assets.reduce(.zero) { $0 + $1.balance }
    }

    var fiatValue: Decimal {
        assets.reduce(.zero) { $0 + $1.fiatValue }
    }
}

enum WalletAssetSelectionCatalog {
    struct Section: Identifiable, Sendable {
        let kind: WalletAssetCatalogOrdering.SectionKind
        let groups: [WalletAssetSelectionGroup]

        var id: Int { kind.id }
    }

    private struct CatalogMaps {
        let tokenIDByAssetIdentity: [String: String]
        let tokenByID: [String: ReceiveToken]
    }

    private static let catalogMapsLock = NSLock()
    nonisolated(unsafe) private static var cachedCatalogMaps:
        (generation: UInt64, value: CatalogMaps)?

    private static var catalogMaps: CatalogMaps {
        let snapshot = ReceiveAssetCatalogRuntime.snapshot
        return catalogMapsLock.withLock {
            if let cachedCatalogMaps,
               cachedCatalogMaps.generation == snapshot.generation {
                return cachedCatalogMaps.value
            }
            let value = CatalogMaps(
                tokenIDByAssetIdentity: Dictionary(
                    snapshot.tokens.flatMap { token in
                        token.variants.map {
                            (
                                AssetIdentityKey.canonical(
                                    $0.assetIdentity
                                ),
                                token.id
                            )
                        }
                    },
                    uniquingKeysWith: { first, _ in first }
                ),
                tokenByID: Dictionary(
                    uniqueKeysWithValues: snapshot.tokens.map {
                        ($0.id, $0)
                    }
                )
            )
            cachedCatalogMaps = (snapshot.generation, value)
            return value
        }
    }

    static func sections(
        from assets: [WalletAsset],
        selectedNetwork: WalletBlockchain?,
        searchText: String,
        transactions: [WalletTransaction] = []
    ) -> [Section] {
        let networkAssets = selectedNetwork.map { network in
            assets.filter { $0.network == network }
        } ?? assets
        guard !Task.isCancelled else { return [] }
        let orderedAssets = AssetDiscoveryRanking.assets(
            networkAssets,
            transactions: transactions,
            searchText: searchText
        )
        let visibleLimit = selectedNetwork == nil
            ? ReceiveAssetSearchIndex.maximumVisibleResults
            : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
        return sections(
            fromOrderedAssets: Array(
                orderedAssets.prefix(visibleLimit)
            )
        )
    }

    static func sections(
        fromOrderedAssets assets: [WalletAsset]
    ) -> [Section] {
        let groups = groups(fromOrderedAssets: assets)
        return [
            WalletAssetCatalogOrdering.SectionKind.holdings,
            .allCrypto
        ].compactMap { kind in
            let matching = groups.filter { sectionKind(for: $0) == kind }
            guard !matching.isEmpty else { return nil }
            return Section(kind: kind, groups: matching)
        }
    }

    static func groups(
        from assets: [WalletAsset],
        selectedNetwork: WalletBlockchain?,
        searchText: String,
        transactions: [WalletTransaction] = []
    ) -> [WalletAssetSelectionGroup] {
        sections(
            from: assets,
            selectedNetwork: selectedNetwork,
            searchText: searchText,
            transactions: transactions
        )
        .flatMap(\.groups)
    }

    static func networkName(for asset: WalletAsset) -> String? {
        guard let network = asset.network else { return nil }
        if let receiveNetwork = ReceiveNetworkCatalog.network(
            for: network
        ) {
            return receiveNetwork.localizedName
        }
        return BitcoinFamilyChain.allCases.first {
            $0.blockchain == network
        }?.name
    }

    static func groups(
        fromOrderedAssets assets: [WalletAsset]
    ) -> [WalletAssetSelectionGroup] {
        let maps = catalogMaps
        return assets.map { asset in
            let identity = AssetIdentityKey.canonical(asset.id)
            let tokenID = maps.tokenIDByAssetIdentity[identity]
            let token = tokenID.flatMap { maps.tokenByID[$0] }
            return WalletAssetSelectionGroup(
                id: "asset:\(identity)",
                token: token,
                name: asset.name,
                symbol: asset.symbol,
                assets: [asset]
            )
        }
    }

    private static func sectionKind(
        for group: WalletAssetSelectionGroup
    ) -> WalletAssetCatalogOrdering.SectionKind {
        if group.fiatValue > .zero
            || group.balance != .zero
            || group.assets.contains(where: \.isPinned) {
            return .holdings
        }
        return .allCrypto
    }
}
