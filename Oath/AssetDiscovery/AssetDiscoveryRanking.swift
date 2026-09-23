import Foundation

enum AssetDiscoverySelection: Identifiable, Sendable {
    case walletAsset(WalletAsset)
    case catalog(ReceiveVariantSelection)

    var id: String {
        "asset:\(canonicalAssetIdentity)"
    }

    var canonicalAssetIdentity: String {
        switch self {
        case let .walletAsset(asset):
            AssetIdentityKey.canonical(asset.id)
        case let .catalog(selection):
            selection.id
        }
    }

    var isWalletAsset: Bool {
        guard case .walletAsset = self else { return false }
        return true
    }

    func isNativeAsset(for networkID: String) -> Bool {
        // A family chip's native asset is its chain's coin: it leads the
        // list because it pays the gas that moves the family's members.
        let networkID = AssetFamily.selectorFamily(for: networkID)?.networkID
            ?? networkID
        let expectedNetworkID =
            WalletNetworkSelectionOrdering.canonicalNetworkID(
                networkID
            ) ?? networkID

        switch self {
        case let .walletAsset(asset):
            guard
                case .nativeCoin = asset.logoSource,
                let assetNetworkID =
                    AssetNetworkSelectorOption.networkID(
                        for: asset.network
                    )
            else {
                return false
            }
            return WalletNetworkSelectionOrdering.canonicalNetworkID(
                assetNetworkID
            ) == expectedNetworkID
        case let .catalog(selection):
            return selection.variant.contractAddress == nil
                && WalletNetworkSelectionOrdering.canonicalNetworkID(
                    selection.variant.networkID
                ) == expectedNetworkID
        }
    }
}

enum AssetDiscoverySelectionOrdering {
    static func nativeFirst(
        _ selections: [AssetDiscoverySelection],
        networkID: String?
    ) -> [AssetDiscoverySelection] {
        guard
            let networkID,
            let nativeIndex = selections.firstIndex(where: {
                $0.isNativeAsset(for: networkID)
            }),
            nativeIndex != selections.startIndex
        else {
            return selections
        }

        var ordered = selections
        let native = ordered.remove(at: nativeIndex)
        ordered.insert(native, at: ordered.startIndex)
        return ordered
    }

    static func deduplicatedPreferringWalletAssets(
        _ selections: [AssetDiscoverySelection]
    ) -> [AssetDiscoverySelection] {
        var ordered: [AssetDiscoverySelection] = []
        var indexByIdentity: [String: Int] = [:]
        ordered.reserveCapacity(selections.count)

        for selection in selections {
            let identity = selection.canonicalAssetIdentity
            if let existingIndex = indexByIdentity[identity] {
                if selection.isWalletAsset,
                   !ordered[existingIndex].isWalletAsset {
                    ordered[existingIndex] = selection
                }
                continue
            }
            indexByIdentity[identity] = ordered.count
            ordered.append(selection)
        }
        return ordered
    }

    static func orderedForSelectedNetwork(
        _ selections: [AssetDiscoverySelection],
        networkID: String?,
        searchText: String,
        availableDirectAssets: [WalletAsset]
    ) -> [AssetDiscoverySelection] {
        var ordered = deduplicatedPreferringWalletAssets(
            selections
        )
        if AssetDiscoveryRanking.normalized(searchText).isEmpty,
           let networkID,
           !ordered.contains(where: {
               $0.isNativeAsset(for: networkID)
           }),
           let blockchain =
               AssetNetworkSelectorOption.blockchain(
                   for: networkID
               ),
           let directNativeAsset =
               availableDirectAssets.first(where: {
                   guard
                       $0.network == blockchain,
                       case .nativeCoin = $0.logoSource
                   else {
                       return false
                   }
                   return true
               }) {
            ordered.append(.walletAsset(directNativeAsset))
        }
        return nativeFirst(
            ordered,
            networkID: networkID
        )
    }
}

enum WalletAssetLiveSelectionProjection {
    static func selections(
        indexedSelections: [AssetDiscoverySelection],
        walletAssets: [WalletAsset],
        directAssetsByIdentity: [String: WalletAsset],
        transactions: [WalletTransaction],
        networkID: String?,
        searchText: String,
        eligibleSolanaTokenMints: Set<String>,
        visibleLimit: Int
    ) -> [AssetDiscoverySelection] {
        let walletAssetsByIdentity = Dictionary(
            walletAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: AssetDiscoveryRanking.preferredAsset
        )
        let funded = fundedSelections(
            walletAssets: walletAssets,
            directAssetsByIdentity: directAssetsByIdentity,
            transactions: transactions,
            networkID: networkID,
            searchText: searchText
        )
        let current = (funded + indexedSelections).compactMap {
            selection -> AssetDiscoverySelection? in
            switch selection {
            case let .walletAsset(asset):
                return walletAssetsByIdentity[
                    AssetIdentityKey.canonical(asset.id)
                ].map(AssetDiscoverySelection.walletAsset)
            case let .catalog(catalogSelection):
                return isEligibleCatalogSelection(
                    catalogSelection,
                    eligibleSolanaTokenMints:
                        eligibleSolanaTokenMints
                ) ? selection : nil
            }
        }
        let ordered = AssetDiscoverySelectionOrdering
            .orderedForSelectedNetwork(
                current,
                networkID: networkID,
                searchText: searchText,
                availableDirectAssets:
                    Array(directAssetsByIdentity.values)
            )
        return Array(ordered.prefix(visibleLimit))
    }

    static func fundedSelections(
        walletAssets: [WalletAsset],
        directAssetsByIdentity: [String: WalletAsset],
        transactions: [WalletTransaction],
        networkID: String?,
        searchText: String
    ) -> [AssetDiscoverySelection] {
        let fundedAssets = walletAssets.filter { asset in
            (asset.balance > 0 || asset.fiatValue > 0)
                && AssetNetworkSelectorOption.includes(asset, in: networkID)
        }
        return AssetDiscoveryRanking.assets(
            fundedAssets,
            transactions: transactions,
            searchText: searchText
        ).compactMap { asset in
            let identity = AssetIdentityKey.canonical(asset.id)
            if let direct = directAssetsByIdentity[identity] {
                return .walletAsset(direct)
            }
            if let catalog = ReceiveAssetCatalog.selection(
                assetIdentity: identity
            ) {
                return .catalog(catalog)
            }
            return .walletAsset(asset)
        }
    }

    private static func isEligibleCatalogSelection(
        _ selection: ReceiveVariantSelection,
        eligibleSolanaTokenMints: Set<String>
    ) -> Bool {
        guard
            selection.variant.networkID == SolanaConstants.networkID,
            let mint = selection.variant.contractAddress
        else {
            return true
        }
        return eligibleSolanaTokenMints.contains(mint)
    }
}

enum AssetDiscoveryRanking {
    fileprivate struct Activity: Sendable {
        var count = 0
        var latestDate: Date?
    }

    struct SearchDocument: Sendable {
        let normalizedName: String
        let normalizedSymbol: String
        let normalizedNetworkAliases: [String]
        let normalizedContractAddress: String

        init(
            name: String,
            symbol: String,
            networkName: String,
            contractAddress: String,
            networkID: String? = nil,
            blockchain: WalletBlockchain? = nil
        ) {
            normalizedName = AssetDiscoveryRanking.normalized(name)
            normalizedSymbol = AssetDiscoveryRanking.normalized(symbol)
            normalizedNetworkAliases =
                AssetNetworkSearchMetadata.aliases(
                    networkID: networkID,
                    blockchain: blockchain,
                    localizedName: networkName
                )
                .map(AssetDiscoveryRanking.normalized)
                .filter { !$0.isEmpty }
            normalizedContractAddress = AssetDiscoveryRanking.normalized(
                contractAddress
            )
        }
    }

    struct Context: Sendable {
        fileprivate let holdings: [String: WalletAsset]
        fileprivate let activity: [String: Activity]
        fileprivate let searchDocuments: [String: SearchDocument]

        init(
            walletAssets: [WalletAsset],
            transactions: [WalletTransaction],
            holdingsByIdentity: [String: WalletAsset]? = nil
        ) {
            holdings = holdingsByIdentity ?? Dictionary(
                walletAssets.map {
                    (AssetIdentityKey.canonical($0.id), $0)
                },
                uniquingKeysWith: AssetDiscoveryRanking.preferredHolding
            )
            activity = AssetDiscoveryRanking.activityByIdentity(
                transactions
            )
            searchDocuments = Dictionary(
                walletAssets.map { asset in
                    (
                        AssetIdentityKey.canonical(asset.id),
                        SearchDocument(
                            name: asset.name,
                            symbol: asset.symbol,
                            networkName:
                                WalletAssetSelectionCatalog.networkName(
                                    for: asset
                                ) ?? "",
                            contractAddress:
                                asset.logoSource
                                    .checksummedContractAddress
                                    ?? AssetIdentityKey.contractAddress(
                                        from: asset.id
                                    )
                                    ?? "",
                            networkID:
                                AssetNetworkSelectorOption.networkID(
                                    for: asset.network
                                ),
                            blockchain: asset.network
                        )
                    )
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    private struct Rank: Sendable {
        let positiveFiatValue: Decimal
        let nativeSearchPriority: Int
        let searchRelevance: Int
        let activityCount: Int
        let latestActivityDate: Date?
        let networkRank: Int
        let globalRank: Int
        let nativeRank: Int
        let normalizedName: String
        let normalizedSymbol: String
        let identity: String
    }

    private static let nativeRankByBlockchain: [
        WalletBlockchain: Int
    ] = Dictionary(
        uniqueKeysWithValues: (
            BitcoinFamilyChain.allCases.map(\.blockchain)
                + ReceiveNetworkCatalog.all.map(\.blockchain)
        )
        .enumerated()
        .map { ($0.element, $0.offset) }
    )

    private static let canonicalNativeNetworkIDBySymbol: [String: String] = {
        var result: [String: String] = [:]
        for chain in BitcoinFamilyChain.allCases {
            let symbol = normalized(chain.symbol)
            if result[symbol] == nil {
                result[symbol] = chain.networkID
            }
        }
        for network in ReceiveNetworkCatalog.all {
            let symbol = normalized(network.symbol)
            if result[symbol] == nil {
                result[symbol] = network.id
            }
        }
        return result
    }()

    static func selections(
        _ selections: [ReceiveVariantSelection],
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        searchText: String,
        context suppliedContext: Context? = nil
    ) -> [ReceiveVariantSelection] {
        let query = normalized(searchText)
        let context = suppliedContext ?? Context(
            walletAssets: walletAssets,
            transactions: transactions
        )
        var ranked: [(ReceiveVariantSelection, Rank)] = []
        ranked.reserveCapacity(selections.count)

        for selection in selections {
            let selectionRank = rank(
                selection: selection,
                holding: context.holdings[selection.id],
                activity: context.activity[selection.id],
                query: query
            )
            guard query.isEmpty || selectionRank.searchRelevance > 0 else {
                continue
            }
            ranked.append((selection, selectionRank))
        }

        return ranked.sorted {
            precedes($0.1, $1.1)
        }
        .map(\.0)
    }

    static func combinedSelections(
        directAssets: [WalletAsset],
        catalogSelections: [ReceiveVariantSelection],
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        searchText: String,
        holdingsByIdentity: [String: WalletAsset]? = nil,
        context suppliedContext: Context? = nil
    ) -> [AssetDiscoverySelection] {
        let query = normalized(searchText)
        let context = suppliedContext ?? Context(
            walletAssets: walletAssets,
            transactions: transactions,
            holdingsByIdentity: holdingsByIdentity
        )
        var ranked: [(AssetDiscoverySelection, Rank)] = []
        ranked.reserveCapacity(
            directAssets.count + catalogSelections.count
        )

        for asset in directAssets {
            let assetRank = rank(
                asset: asset,
                activity: context.activity[
                    AssetIdentityKey.canonical(asset.id)
                ],
                searchDocument:
                    context.searchDocuments[
                        AssetIdentityKey.canonical(asset.id)
                    ],
                query: query
            )
            guard query.isEmpty || assetRank.searchRelevance > 0 else {
                continue
            }
            ranked.append((.walletAsset(asset), assetRank))
        }

        for selection in catalogSelections {
            let selectionRank = rank(
                selection: selection,
                holding: context.holdings[selection.id],
                activity: context.activity[selection.id],
                query: query
            )
            guard query.isEmpty || selectionRank.searchRelevance > 0 else {
                continue
            }
            ranked.append((.catalog(selection), selectionRank))
        }

        return ranked.sorted {
            precedes($0.1, $1.1)
        }
        .map(\.0)
    }

    static func assets(
        _ assets: [WalletAsset],
        transactions: [WalletTransaction],
        searchText: String,
        context suppliedContext: Context? = nil
    ) -> [WalletAsset] {
        let query = normalized(searchText)
        let context = suppliedContext ?? Context(
            walletAssets: assets,
            transactions: transactions
        )
        var ranked: [(WalletAsset, Rank)] = []
        ranked.reserveCapacity(assets.count)

        for asset in assets {
            let assetRank = rank(
                asset: asset,
                activity: context.activity[
                    AssetIdentityKey.canonical(asset.id)
                ],
                searchDocument:
                    context.searchDocuments[
                        AssetIdentityKey.canonical(asset.id)
                    ],
                query: query
            )
            guard query.isEmpty || assetRank.searchRelevance > 0 else {
                continue
            }
            ranked.append((asset, assetRank))
        }

        return ranked.sorted {
            precedes($0.1, $1.1)
        }
        .map(\.0)
    }

    static func hasActivity(
        assetIdentity: String,
        transactions: [WalletTransaction]
    ) -> Bool {
        activityByIdentity(transactions)[
            AssetIdentityKey.canonical(assetIdentity)
        ] != nil
    }

    static func activeAssetIdentities(
        transactions: [WalletTransaction]
    ) -> Set<String> {
        Set(activityByIdentity(transactions).keys)
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }

    static func searchDocument(
        for asset: WalletAsset
    ) -> SearchDocument {
        SearchDocument(
            name: asset.name,
            symbol: asset.symbol,
            networkName:
                WalletAssetSelectionCatalog.networkName(for: asset) ?? "",
            contractAddress:
                asset.logoSource.checksummedContractAddress
                    ?? AssetIdentityKey.contractAddress(from: asset.id)
                    ?? "",
            networkID:
                AssetNetworkSelectorOption.networkID(for: asset.network),
            blockchain: asset.network
        )
    }

    static func preferredAsset(
        _ lhs: WalletAsset,
        _ rhs: WalletAsset
    ) -> WalletAsset {
        preferredHolding(lhs, rhs)
    }

    static func matches(
        normalizedQuery query: String,
        document: SearchDocument
    ) -> Bool {
        relevance(query: query, document: document) > 0
    }

    private static func rank(
        selection: ReceiveVariantSelection,
        holding: WalletAsset?,
        activity: Activity?,
        query: String
    ) -> Rank {
        let searchDocument = ReceiveAssetSearchIndex.searchDocument(
            for: selection
        )
        return Rank(
            positiveFiatValue: positive(holding?.fiatValue),
            nativeSearchPriority: nativeSearchPriority(
                query: query,
                isNative: selection.variant.contractAddress == nil,
                networkID: selection.variant.networkID,
                symbol: selection.token.symbol
            ),
            searchRelevance: relevance(
                query: query,
                document: searchDocument
            ),
            activityCount: activity?.count ?? 0,
            latestActivityDate: activity?.latestDate,
            networkRank: selection.variant.networkRank ?? Int.max,
            globalRank: selection.token.rank,
            nativeRank: nativeRank(
                for: selection.variant.network?.blockchain
            ),
            normalizedName: searchDocument.normalizedName,
            normalizedSymbol: searchDocument.normalizedSymbol,
            identity: selection.id
        )
    }

    private static func rank(
        asset: WalletAsset,
        activity: Activity?,
        searchDocument suppliedSearchDocument: SearchDocument?,
        query: String
    ) -> Rank {
        let strength = ReceiveAssetCatalog.strength(for: asset)
        let searchDocument = suppliedSearchDocument
            ?? searchDocument(for: asset)
        return Rank(
            positiveFiatValue: positive(asset.fiatValue),
            nativeSearchPriority: nativeSearchPriority(
                query: query,
                isNative: strength.isNative,
                networkID: AssetNetworkSelectorOption.networkID(
                    for: asset.network
                ),
                symbol: asset.symbol
            ),
            searchRelevance: relevance(
                query: query,
                document: searchDocument
            ),
            activityCount: activity?.count ?? 0,
            latestActivityDate: activity?.latestDate,
            networkRank: strength.networkRank,
            globalRank: strength.globalRank,
            nativeRank: nativeRank(for: asset.network),
            normalizedName: searchDocument.normalizedName,
            normalizedSymbol: searchDocument.normalizedSymbol,
            identity: AssetIdentityKey.canonical(asset.id)
        )
    }

    private static func precedes(_ lhs: Rank, _ rhs: Rank) -> Bool {
        if lhs.positiveFiatValue != rhs.positiveFiatValue {
            return lhs.positiveFiatValue > rhs.positiveFiatValue
        }
        // A searched holding with more value must remain first. Only when
        // values tie does the canonical coin on its own mainnet outrank
        // same-name or same-symbol tokens issued on other networks.
        if lhs.nativeSearchPriority != rhs.nativeSearchPriority {
            return lhs.nativeSearchPriority > rhs.nativeSearchPriority
        }
        if lhs.searchRelevance != rhs.searchRelevance {
            return lhs.searchRelevance > rhs.searchRelevance
        }
        if lhs.activityCount != rhs.activityCount {
            return lhs.activityCount > rhs.activityCount
        }
        if lhs.latestActivityDate != rhs.latestActivityDate {
            return (lhs.latestActivityDate ?? .distantPast)
                > (rhs.latestActivityDate ?? .distantPast)
        }
        if lhs.networkRank != rhs.networkRank {
            return lhs.networkRank < rhs.networkRank
        }
        if lhs.globalRank != rhs.globalRank {
            return lhs.globalRank < rhs.globalRank
        }
        if lhs.nativeRank != rhs.nativeRank {
            return lhs.nativeRank < rhs.nativeRank
        }
        if lhs.normalizedName != rhs.normalizedName {
            return lhs.normalizedName < rhs.normalizedName
        }
        if lhs.normalizedSymbol != rhs.normalizedSymbol {
            return lhs.normalizedSymbol < rhs.normalizedSymbol
        }
        return lhs.identity < rhs.identity
    }

    private static func relevance(
        query: String,
        document: SearchDocument
    ) -> Int {
        guard !query.isEmpty else { return 0 }
        let normalizedName = document.normalizedName
        let normalizedSymbol = document.normalizedSymbol
        let normalizedNetworks = document.normalizedNetworkAliases
        let normalizedContract = document.normalizedContractAddress

        if normalizedName == query { return 700 }
        if normalizedSymbol == query { return 680 }
        if normalizedContract == query { return 660 }
        if normalizedName.hasPrefix(query) { return 600 }
        if normalizedSymbol.hasPrefix(query) { return 580 }
        if words(in: normalizedName).contains(where: {
            $0.hasPrefix(query)
        }) {
            return 540
        }
        if normalizedContract.hasPrefix(query) { return 440 }
        if normalizedContract.contains(query) { return 420 }
        if normalizedNetworks.contains(query) { return 380 }
        if normalizedNetworks.contains(where: { networkAlias in
            words(in: networkAlias).contains(where: {
                $0.hasPrefix(query)
            })
        }) {
            return 300
        }

        let queryTerms = searchTerms(in: query)
        guard
            queryTerms.count > 1,
            queryTerms.allSatisfy({
                documentMatches(
                    term: $0,
                    normalizedName: normalizedName,
                    normalizedSymbol: normalizedSymbol,
                    normalizedNetworks: normalizedNetworks,
                    normalizedContract: normalizedContract
                )
            })
        else {
            return 0
        }
        return 400 + min(queryTerms.count, 10) * 10
    }

    private static func documentMatches(
        term: Substring,
        normalizedName: String,
        normalizedSymbol: String,
        normalizedNetworks: [String],
        normalizedContract: String
    ) -> Bool {
        let term = String(term)
        if words(in: normalizedName).contains(Substring(term)) {
            return true
        }
        if normalizedSymbol == term {
            return true
        }
        if term.count >= 6,
           normalizedContract.hasPrefix(term)
            || normalizedContract.contains(term) {
            return true
        }
        return normalizedNetworks.contains { networkAlias in
            networkAlias == term
                || words(in: networkAlias).contains(Substring(term))
        }
    }

    private static func searchTerms(
        in normalizedQuery: String
    ) -> [Substring] {
        normalizedQuery.split(whereSeparator: \.isWhitespace)
    }

    private static func words(
        in normalizedValue: String
    ) -> [Substring] {
        normalizedValue.split {
            !$0.isLetter && !$0.isNumber
        }
    }

    private static func positive(_ value: Decimal?) -> Decimal {
        guard let value, value > 0 else { return 0 }
        return value
    }

    private static func nativeSearchPriority(
        query: String,
        isNative: Bool,
        networkID: String?,
        symbol: String
    ) -> Int {
        guard !query.isEmpty, isNative else { return 0 }
        guard
            let networkID = WalletNetworkSelectionOrdering
                .canonicalNetworkID(networkID),
            canonicalNativeNetworkIDBySymbol[normalized(symbol)]
                == networkID
        else {
            return 1
        }
        return 2
    }

    private static func preferredHolding(
        _ lhs: WalletAsset,
        _ rhs: WalletAsset
    ) -> WalletAsset {
        lhs.fiatValue >= rhs.fiatValue ? lhs : rhs
    }

    private static func activityByIdentity(
        _ transactions: [WalletTransaction]
    ) -> [String: Activity] {
        var result: [String: Activity] = [:]
        for transaction in transactions where
            WalletTransactionVisibilityPolicy.includes(transaction) {
            guard let identity = identity(for: transaction) else { continue }
            var activity = result[identity] ?? Activity()
            activity.count += 1
            if let date = transaction.metadata.date,
               date > (activity.latestDate ?? .distantPast) {
                activity.latestDate = date
            }
            result[identity] = activity
        }
        return result
    }

    private static func identity(
        for transaction: WalletTransaction
    ) -> String? {
        let networkID = transaction.metadata.blockchainIdentifier
            ?? AssetNetworkSelectorOption.networkID(
                for: transaction.assetLogoSource.blockchain
            )
        guard let networkID else { return nil }

        let contract = transaction.metadata.contractAddress
            ?? transaction.assetLogoSource.checksummedContractAddress
        guard let contract, !contract.isEmpty else {
            return AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: nil
            )
        }
        return AssetIdentityKey.make(
            networkID: networkID,
            contractAddress: contract
        )
    }

    private static func nativeRank(
        for blockchain: WalletBlockchain?
    ) -> Int {
        guard let blockchain else { return Int.max }
        return nativeRankByBlockchain[blockchain] ?? Int.max
    }
}

enum AssetNetworkSearchMetadata {
    static func aliases(
        networkID: String?,
        blockchain: WalletBlockchain?,
        localizedName: String
    ) -> [String] {
        let resolvedNetworkID =
            WalletNetworkSelectionOrdering.canonicalNetworkID(networkID)
            ?? AssetNetworkSelectorOption.networkID(for: blockchain)
        var values = [
            localizedName,
            networkID ?? "",
            resolvedNetworkID ?? "",
            blockchain?.rawValue ?? ""
        ]
        if let resolvedNetworkID {
            values.append(
                resolvedNetworkID
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
            )
            values.append(
                contentsOf:
                    aliasesByNetworkID[resolvedNetworkID] ?? []
            )
        }

        var seen = Set<String>()
        return values.filter { value in
            let normalized = AssetDiscoveryRanking.normalized(value)
            return !normalized.isEmpty && seen.insert(normalized).inserted
        }
    }

    private static let aliasesByNetworkID: [String: [String]] = [
        "aptos": [
            "Aptos",
            "APT"
        ],
        "stellar": [
            "Stellar",
            "Stellar Mainnet",
            "XLM"
        ],
        "bitcoin": [
            "Bitcoin",
            "BTC"
        ],
        "bitcoin_cash": [
            "Bitcoin Cash",
            "BitcoinCash",
            "BCH"
        ],
        "litecoin": [
            "Litecoin",
            "LTC"
        ],
        "dogecoin": [
            "Dogecoin",
            "DOGE"
        ],
        "eth": [
            "Ethereum",
            "Ethereum Mainnet",
            "ETH"
        ],
        "tron": [
            "TRON",
            "TRX"
        ],
        "solana": [
            "Solana",
            "SOL"
        ],
        "ton": [
            "TON",
            "The Open Network",
            "GRAM"
        ],
        "sui": [
            "Sui",
            "SUI"
        ],
        "near": [
            "NEAR",
            "NEAR Protocol"
        ],
        "xrp": [
            "XRP Ledger",
            "XRPL",
            "XRP"
        ],
        "bsc": [
            "BNB Smart Chain",
            "Binance Smart Chain",
            "BSC",
            "BNB",
            "Smart Chain"
        ],
        "arbitrum": [
            "Arbitrum",
            "Arbitrum One",
            "ARB"
        ],
        "base": [
            "Base",
            "Base Mainnet"
        ],
        "polygon": [
            "Polygon",
            "Polygon PoS",
            "POL",
            "MATIC"
        ],
        "optimism": [
            "Optimism",
            "Optimism Mainnet",
            "OP"
        ],
        "avalanche": [
            "Avalanche",
            "Avalanche C-Chain",
            "Avalanche C Chain",
            "AVAX"
        ],
        "gnosis": [
            "Gnosis",
            "Gnosis Chain",
            "xDai",
            "GNO"
        ],
        "linea": [
            "Linea"
        ],
        "scroll": [
            "Scroll"
        ],
        "taiko": [
            "Taiko"
        ],
        "telos": [
            "Telos",
            "TLOS"
        ],
        "arc": [
            "Arc"
        ],
        "xlayer": [
            "X Layer",
            "X-Layer",
            "XLayer",
            "OKB"
        ]
    ]
}
