import Foundation

enum ReceiveAssetSearchIndex {
    static let maximumVisibleResults = 250

    private struct Index {
        let generation: UInt64
        let languageIdentifier: String
        let allSelections: [ReceiveVariantSelection]
        let selectionsByNetworkID: [String: [ReceiveVariantSelection]]
        let selectionByID: [String: ReceiveVariantSelection]
        let queryIndex: AssetTextQueryIndex

        init(
            snapshot: ReceiveAssetCatalogRuntimeSnapshot,
            languageIdentifier: String
        ) {
            generation = snapshot.generation
            self.languageIdentifier = languageIdentifier
            allSelections = snapshot.tokens.flatMap { token in
                token.variants.compactMap { variant in
                    guard variant.network != nil else { return nil }
                    return ReceiveVariantSelection(
                        token: token,
                        variant: variant
                    )
                }
            }
            var byNetwork = Dictionary(
                grouping: allSelections,
                by: { $0.variant.networkID }
            )
            // A family chip lists the chain's native coin first — it pays
            // the gas that moves the members — and then the members.
            for family in AssetFamily.allCases {
                let native = allSelections.first {
                    $0.variant.networkID == family.networkID
                        && $0.variant.contractAddress == nil
                }
                byNetwork[family.selectorID] = (native.map { [$0] } ?? [])
                    + allSelections.filter { $0.variant.family == family }
            }
            selectionsByNetworkID = byNetwork
            selectionByID = Dictionary(
                allSelections.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            queryIndex = AssetTextQueryIndex(
                entries: allSelections.map { selection in
                    (
                        id: selection.id,
                        document: AssetDiscoveryRanking.SearchDocument(
                            name: selection.token.name,
                            symbol: selection.token.symbol,
                            networkName: selection.variant.network?
                                .localizedName ?? "",
                            contractAddress:
                                selection.variant.contractAddress ?? "",
                            networkID: selection.variant.networkID,
                            blockchain:
                                selection.variant.network?.blockchain
                        )
                    )
                }
            )
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedIndex: Index?

    private static var index: Index {
        let snapshot = ReceiveAssetCatalogRuntime.snapshot
        let languageIdentifier = WalletAppLanguage.selectedIdentifier
        return lock.withLock {
            if let cachedIndex,
               cachedIndex.generation == snapshot.generation,
               cachedIndex.languageIdentifier == languageIdentifier {
                return cachedIndex
            }
            let value = Index(
                snapshot: snapshot,
                languageIdentifier: languageIdentifier
            )
            cachedIndex = value
            return value
        }
    }

    static func candidates(
        networkID: String?
    ) -> [ReceiveVariantSelection] {
        let index = Self.index
        guard let networkID else {
            return index.allSelections
        }
        return index.selectionsByNetworkID[networkID] ?? []
    }

    static func candidates(
        networkID: String?,
        matching searchText: String
    ) -> [ReceiveVariantSelection] {
        let index = Self.index
        guard let match = index.queryIndex.match(searchText: searchText)
        else {
            guard let networkID else { return index.allSelections }
            return index.selectionsByNetworkID[networkID] ?? []
        }
        let selectedFamily = AssetFamily.selectorFamily(for: networkID)
        let matched = match.identifiers
            .compactMap { index.selectionByID[$0] }
            .filter { selection in
                guard let networkID else { return true }
                if selection.variant.networkID == networkID { return true }
                guard let selectedFamily else { return false }
                return selection.variant.family == selectedFamily
                    || (
                        selection.variant.networkID == selectedFamily.networkID
                            && selection.variant.contractAddress == nil
                    )
            }
        guard match.precision == .exactName,
              let strongestRank = matched.map(\.token.rank).min()
        else {
            return matched
        }
        return matched.filter { $0.token.rank == strongestRank }
    }

    static func prepare() {
        _ = Self.index.queryIndex.count
    }

    static func selections(
        matching searchText: String,
        networkID: String? = nil,
        walletAssets: [WalletAsset] = [],
        transactions: [WalletTransaction] = []
    ) -> [ReceiveVariantSelection] {
        let visibleLimit = networkID == nil
            ? maximumVisibleResults
            : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
        return Array(
            AssetDiscoveryRanking.selections(
                candidates(
                    networkID: networkID,
                    matching: searchText
                ),
                walletAssets: walletAssets,
                transactions: transactions,
                searchText: searchText
            )
            .prefix(visibleLimit)
        )
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
        for selection: ReceiveVariantSelection
    ) -> AssetDiscoveryRanking.SearchDocument {
        Self.index.queryIndex.document(for: selection.id)
            ?? AssetDiscoveryRanking.SearchDocument(
                name: selection.token.name,
                symbol: selection.token.symbol,
                networkName:
                    selection.variant.network?.localizedName ?? "",
                contractAddress:
                    selection.variant.contractAddress ?? "",
                networkID: selection.variant.networkID,
                blockchain: selection.variant.network?.blockchain
            )
    }
}
