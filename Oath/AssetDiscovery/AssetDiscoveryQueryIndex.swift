import Foundation

struct AssetTextQueryMatch: Sendable {
    enum Precision: Equatable, Sendable {
        case exactName
        case exactSymbol
        case prefix
    }

    let identifiers: Set<String>
    let precision: Precision
}

struct AssetTextQueryIndex: Sendable {
    private struct TrieNode: Sendable {
        var children: [Character: Int] = [:]
        var documentIndices: [Int] = []
    }

    private struct TrieBuilderNode {
        var children: [Character: Int] = [:]
        var documentIndices = Set<Int>()
    }

    private let identifiers: [String]
    private let documentsByIdentifier:
        [String: AssetDiscoveryRanking.SearchDocument]
    private let trie: [TrieNode]
    private let exactContractDocumentIndices: [String: [Int]]
    private let exactNameDocumentIndices: [String: [Int]]
    private let exactSymbolDocumentIndices: [String: [Int]]
    private let networkTerms: Set<String>

    init(
        entries: [
            (
                id: String,
                document: AssetDiscoveryRanking.SearchDocument
            )
        ]
    ) {
        var seenIdentifiers = Set<String>()
        let uniqueEntries = entries.filter {
            seenIdentifiers.insert($0.id).inserted
        }
        identifiers = uniqueEntries.map(\.id)
        documentsByIdentifier = Dictionary(
            uniqueEntries.map { ($0.id, $0.document) },
            uniquingKeysWith: { first, _ in first }
        )

        var nodes = [TrieBuilderNode()]
        var exactContracts: [String: Set<Int>] = [:]
        var exactNames: [String: Set<Int>] = [:]
        var exactSymbols: [String: Set<Int>] = [:]
        var indexedNetworkTerms = Set<String>()

        func insert(
            _ value: String,
            documentIndex: Int
        ) {
            guard !value.isEmpty else { return }
            var nodeIndex = 0
            for character in value {
                let childIndex: Int
                if let existing = nodes[nodeIndex].children[character] {
                    childIndex = existing
                } else {
                    childIndex = nodes.count
                    nodes.append(TrieBuilderNode())
                    nodes[nodeIndex].children[character] = childIndex
                }
                nodes[childIndex].documentIndices.insert(documentIndex)
                nodeIndex = childIndex
            }
        }

        for (documentIndex, entry) in uniqueEntries.enumerated() {
            let document = entry.document
            var indexedValues = Set<String>()
            indexedValues.insert(document.normalizedName)
            indexedValues.insert(document.normalizedSymbol)
            exactNames[document.normalizedName, default: []]
                .insert(documentIndex)
            exactSymbols[document.normalizedSymbol, default: []]
                .insert(documentIndex)
            indexedValues.formUnion(
                Self.words(in: document.normalizedName)
            )
            for alias in document.normalizedNetworkAliases {
                indexedValues.insert(alias)
                let aliasWords = Self.words(in: alias)
                indexedValues.formUnion(aliasWords)
                indexedNetworkTerms.insert(alias)
                indexedNetworkTerms.formUnion(aliasWords)
            }
            if !document.normalizedContractAddress.isEmpty {
                exactContracts[
                    document.normalizedContractAddress,
                    default: []
                ]
                .insert(documentIndex)
            }
            for value in indexedValues {
                insert(value, documentIndex: documentIndex)
            }
        }

        trie = nodes.map {
            TrieNode(
                children: $0.children,
                documentIndices: Array($0.documentIndices)
            )
        }
        exactContractDocumentIndices =
            exactContracts.mapValues(Array.init)
        exactNameDocumentIndices = exactNames.mapValues(Array.init)
        exactSymbolDocumentIndices = exactSymbols.mapValues(Array.init)
        networkTerms = indexedNetworkTerms
    }

    var count: Int {
        identifiers.count
    }

    func document(
        for identifier: String
    ) -> AssetDiscoveryRanking.SearchDocument? {
        documentsByIdentifier[identifier]
    }

    func matchingIdentifiers(
        searchText: String
    ) -> Set<String>? {
        match(searchText: searchText)?.identifiers
    }

    func match(
        searchText: String
    ) -> AssetTextQueryMatch? {
        let query = AssetDiscoveryRanking.normalized(searchText)
        guard !query.isEmpty else { return nil }
        let terms = Array(Self.words(in: query))
        guard !terms.isEmpty else {
            return AssetTextQueryMatch(
                identifiers: [],
                precision: .prefix
            )
        }

        let networkQualifierTerms: Set<String>
        if terms.count > 1 {
            networkQualifierTerms = Set(
                terms.filter(networkTerms.contains)
            )
        } else {
            networkQualifierTerms = []
        }
        let assetTerms = terms.filter {
            !networkQualifierTerms.contains($0)
        }
        let assetPhrase = assetTerms.joined(separator: " ")
        let exactAssetIndices: Set<Int>?
        let precision: AssetTextQueryMatch.Precision
        if let exactNames = exactNameDocumentIndices[assetPhrase],
           !exactNames.isEmpty {
            exactAssetIndices = Set(exactNames)
            precision = .exactName
        } else if assetTerms.count == 1,
                  let exactSymbols =
                    exactSymbolDocumentIndices[assetTerms[0]],
                  !exactSymbols.isEmpty {
            exactAssetIndices = Set(exactSymbols)
            precision = .exactSymbol
        } else {
            exactAssetIndices = nil
            precision = .prefix
        }

        var matchingIndices = exactAssetIndices
        let remainingTerms = exactAssetIndices == nil
            ? terms
            : terms.filter(networkQualifierTerms.contains)
        for term in remainingTerms {
            let termMatches = documentIndices(matching: term)
            if let existing = matchingIndices {
                matchingIndices = existing.intersection(termMatches)
            } else {
                matchingIndices = termMatches
            }
            if matchingIndices?.isEmpty == true {
                return AssetTextQueryMatch(
                    identifiers: [],
                    precision: precision
                )
            }
        }

        return AssetTextQueryMatch(
            identifiers: Set(
                (matchingIndices ?? []).map { identifiers[$0] }
            ),
            precision: precision
        )
    }

    private func documentIndices(
        matching term: String
    ) -> Set<Int> {
        var nodeIndex = 0
        for character in term {
            guard let next = trie[nodeIndex].children[character] else {
                nodeIndex = -1
                break
            }
            nodeIndex = next
        }

        var matches = nodeIndex >= 0
            ? Set(trie[nodeIndex].documentIndices)
            : []
        matches.formUnion(
            exactContractDocumentIndices[term] ?? []
        )
        return matches
    }

    private static func words(
        in value: String
    ) -> [String] {
        value.split {
            !$0.isLetter && !$0.isNumber
        }
        .map(String.init)
    }
}

struct WalletAssetDiscoveryIndex: Sendable {
    private let transactions: [WalletTransaction]
    private let rankingContext: AssetDiscoveryRanking.Context
    private let orderedAssets: [WalletAsset]
    private let orderedAssetsByNetworkID: [String: [WalletAsset]]
    private let assetsByIdentity: [String: WalletAsset]
    private let searchIndex: AssetTextQueryIndex

    init(
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction]
    ) {
        self.transactions = transactions

        let context = AssetDiscoveryRanking.Context(
            walletAssets: walletAssets,
            transactions: transactions
        )
        rankingContext = context
        assetsByIdentity = Dictionary(
            walletAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: AssetDiscoveryRanking.preferredAsset
        )
        searchIndex = AssetTextQueryIndex(
            entries: assetsByIdentity.map {
                (
                    id: $0.key,
                    document: AssetDiscoveryRanking.searchDocument(
                        for: $0.value
                    )
                )
            }
        )

        let ordered = AssetDiscoveryRanking.assets(
            Array(assetsByIdentity.values),
            transactions: transactions,
            searchText: "",
            context: context
        )
        orderedAssets = ordered
        orderedAssetsByNetworkID = Dictionary(
            grouping: ordered,
            by: Self.networkID
        )
    }

    func assets(
        networkID: String?,
        searchText: String
    ) -> [WalletAsset] {
        guard let matchingIdentities =
            searchIndex.matchingIdentifiers(searchText: searchText) else {
            if let networkID {
                return orderedAssetsByNetworkID[networkID] ?? []
            }
            return orderedAssets
        }
        let candidates = matchingIdentities.compactMap {
            assetsByIdentity[$0]
        }
        .filter {
            networkID == nil || Self.networkID(for: $0) == networkID
        }
        return AssetDiscoveryRanking.assets(
            candidates,
            transactions: transactions,
            searchText: searchText,
            context: rankingContext
        )
    }

    private static func networkID(for asset: WalletAsset) -> String {
        AssetNetworkSelectorOption.networkID(for: asset.network)
            ?? "unavailable"
    }
}

struct CombinedAssetDiscoveryIndex: Sendable {
    private let walletAssets: [WalletAsset]
    private let transactions: [WalletTransaction]
    private let directAssets: [WalletAsset]
    private let directAssetsByIdentity: [String: WalletAsset]
    private let directAssetSearchIndex: AssetTextQueryIndex
    private let rankingContext: AssetDiscoveryRanking.Context
    private let orderedSelections: [AssetDiscoverySelection]
    private let orderedSelectionsByNetworkID:
        [String: [AssetDiscoverySelection]]

    init(
        walletAssets: [WalletAsset],
        directAssets: [WalletAsset],
        transactions: [WalletTransaction],
        holdingsByIdentity: [String: WalletAsset]? = nil
    ) {
        self = Self.build(
            walletAssets: walletAssets,
            directAssets: directAssets,
            transactions: transactions,
            holdingsByIdentity: holdingsByIdentity,
            orderedSelectionsByNetworkID: nil
        )
    }

    static func make(
        walletAssets: [WalletAsset],
        directAssets: [WalletAsset],
        transactions: [WalletTransaction],
        holdingsByIdentity: [String: WalletAsset]? = nil
    ) async -> CombinedAssetDiscoveryIndex {
        let context = AssetDiscoveryRanking.Context(
            walletAssets: walletAssets,
            transactions: transactions,
            holdingsByIdentity: holdingsByIdentity
        )
        let networkIDs = AssetNetworkSelectorOption.allSelectable.map(\.id)
        let byNetwork = await withTaskGroup(
            of: (String, [AssetDiscoverySelection]).self,
            returning: [String: [AssetDiscoverySelection]].self
        ) { group in
            for networkID in networkIDs {
                group.addTask {
                    (
                        networkID,
                        Self.orderedSelections(
                            networkID: networkID,
                            searchText: "",
                            walletAssets: walletAssets,
                            directAssets: directAssets,
                            transactions: transactions,
                            holdingsByIdentity: holdingsByIdentity,
                            rankingContext: context
                        )
                    )
                }
            }
            var result: [String: [AssetDiscoverySelection]] = [:]
            for await (networkID, selections) in group {
                result[networkID] = selections
            }
            return result
        }
        return Self.build(
            walletAssets: walletAssets,
            directAssets: directAssets,
            transactions: transactions,
            holdingsByIdentity: holdingsByIdentity,
            orderedSelectionsByNetworkID: byNetwork
        )
    }

    private static func build(
        walletAssets: [WalletAsset],
        directAssets: [WalletAsset],
        transactions: [WalletTransaction],
        holdingsByIdentity: [String: WalletAsset]?,
        orderedSelectionsByNetworkID suppliedNetworkSelections:
            [String: [AssetDiscoverySelection]]?
    ) -> CombinedAssetDiscoveryIndex {
        let context = AssetDiscoveryRanking.Context(
            walletAssets: walletAssets,
            transactions: transactions,
            holdingsByIdentity: holdingsByIdentity
        )
        let directByIdentity = Dictionary(
            directAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: AssetDiscoveryRanking.preferredAsset
        )
        let directSearchIndex = AssetTextQueryIndex(
            entries: directByIdentity.map {
                (
                    id: $0.key,
                    document: AssetDiscoveryRanking.searchDocument(
                        for: $0.value
                    )
                )
            }
        )
        let globalSelections = orderedSelections(
            networkID: nil,
            searchText: "",
            walletAssets: walletAssets,
            directAssets: Array(directByIdentity.values),
            transactions: transactions,
            holdingsByIdentity: holdingsByIdentity,
            rankingContext: context
        )
        let byNetwork = suppliedNetworkSelections
            ?? Dictionary(
                uniqueKeysWithValues:
                    AssetNetworkSelectorOption.allSelectable.map {
                        option in
                        (
                            option.id,
                            orderedSelections(
                                networkID: option.id,
                                searchText: "",
                                walletAssets: walletAssets,
                                directAssets:
                                    Array(directByIdentity.values),
                                transactions: transactions,
                                holdingsByIdentity: holdingsByIdentity,
                                rankingContext: context
                            )
                        )
                    }
            )

        return CombinedAssetDiscoveryIndex(
            walletAssets: walletAssets,
            transactions: transactions,
            directAssets: Array(directByIdentity.values),
            directAssetsByIdentity: directByIdentity,
            directAssetSearchIndex: directSearchIndex,
            rankingContext: context,
            orderedSelections: globalSelections,
            orderedSelectionsByNetworkID: byNetwork
        )
    }

    private init(
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        directAssets: [WalletAsset],
        directAssetsByIdentity: [String: WalletAsset],
        directAssetSearchIndex: AssetTextQueryIndex,
        rankingContext: AssetDiscoveryRanking.Context,
        orderedSelections: [AssetDiscoverySelection],
        orderedSelectionsByNetworkID:
            [String: [AssetDiscoverySelection]]
    ) {
        self.walletAssets = walletAssets
        self.directAssets = directAssets
        self.transactions = transactions
        self.directAssetsByIdentity = directAssetsByIdentity
        self.directAssetSearchIndex = directAssetSearchIndex
        self.rankingContext = rankingContext
        self.orderedSelections = orderedSelections
        self.orderedSelectionsByNetworkID =
            orderedSelectionsByNetworkID
    }

    func selections(
        networkID: String?,
        searchText: String
    ) -> [AssetDiscoverySelection] {
        let normalizedSearchText = AssetDiscoveryRanking.normalized(
            searchText
        )
        if normalizedSearchText.isEmpty {
            guard let networkID else { return orderedSelections }
            return orderedSelectionsByNetworkID[networkID] ?? []
        }

        let matchingDirectAssets =
            directAssetSearchIndex.matchingIdentifiers(
                searchText: searchText
            )?
            .compactMap { directAssetsByIdentity[$0] }
            .filter {
                AssetNetworkSelectorOption.includes($0, in: networkID)
            } ?? []
        return Self.orderedSelections(
            networkID: networkID,
            searchText: searchText,
            walletAssets: walletAssets,
            directAssets: matchingDirectAssets,
            transactions: transactions,
            holdingsByIdentity: nil,
            rankingContext: rankingContext
        )
    }

    private static func orderedSelections(
        networkID: String?,
        searchText: String,
        walletAssets: [WalletAsset],
        directAssets: [WalletAsset],
        transactions: [WalletTransaction],
        holdingsByIdentity: [String: WalletAsset]?,
        rankingContext: AssetDiscoveryRanking.Context
    ) -> [AssetDiscoverySelection] {
        let scopedDirectAssets = directAssets.filter {
            AssetNetworkSelectorOption.includes($0, in: networkID)
        }
        let catalogLimit = networkID == nil
            ? ReceiveAssetSearchIndex.maximumVisibleResults
            : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
        let catalogSelections = Array(
            AssetDiscoveryRanking.selections(
                ReceiveAssetSearchIndex.candidates(
                    networkID: networkID,
                    matching: searchText
                ),
                walletAssets: walletAssets,
                transactions: transactions,
                searchText: searchText,
                context: rankingContext
            )
            .prefix(catalogLimit)
        )
        let combined = AssetDiscoveryRanking.combinedSelections(
            directAssets: scopedDirectAssets,
            catalogSelections: catalogSelections,
            walletAssets: walletAssets,
            transactions: transactions,
            searchText: searchText,
            holdingsByIdentity: holdingsByIdentity,
            context: rankingContext
        )
        let unique = AssetDiscoverySelectionOrdering
            .deduplicatedPreferringWalletAssets(combined)
        return AssetDiscoverySelectionOrdering.nativeFirst(
            unique,
            networkID: networkID
        )
    }
}
