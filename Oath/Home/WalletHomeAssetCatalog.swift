import Foundation

struct WalletAssetBalanceSnapshot: Sendable {
    private let assetsByIdentity: [String: WalletAsset]

    init(assets: [WalletAsset]) {
        assetsByIdentity = Dictionary(
            assets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: AssetDiscoveryRanking.preferredAsset
        )
    }

    func holding(
        matching candidate: WalletAsset
    ) -> WalletAsset? {
        holding(
            assetIdentity: candidate.id,
            presentationCandidate: candidate
        )
    }

    func holding(
        assetIdentity: String,
        presentationCandidate: WalletAsset? = nil
    ) -> WalletAsset? {
        guard let holding = assetsByIdentity[
            AssetIdentityKey.canonical(assetIdentity)
        ] else {
            return nil
        }
        guard let presentationCandidate else { return holding }
        return Self.holding(
            holding,
            preservingPresentationDataFrom: presentationCandidate
        )
    }

    func resolved(
        _ candidate: WalletAsset
    ) -> WalletAsset {
        holding(matching: candidate) ?? Self.zeroed(candidate)
    }

    func projecting(
        candidates: [WalletAsset],
        includesUnmatchedHoldings: Bool = true
    ) -> [WalletAsset] {
        var projected: [WalletAsset] = []
        projected.reserveCapacity(
            candidates.count
                + (includesUnmatchedHoldings ? assetsByIdentity.count : 0)
        )
        var seen = Set<String>()

        for candidate in candidates {
            let identity = AssetIdentityKey.canonical(candidate.id)
            guard seen.insert(identity).inserted else { continue }
            projected.append(resolved(candidate))
        }

        if includesUnmatchedHoldings {
            projected.append(
                contentsOf: assetsByIdentity
                    .filter { !seen.contains($0.key) }
                    .sorted { $0.key < $1.key }
                    .map(\.value)
            )
        }
        return projected
    }

    private static func holding(
        _ holding: WalletAsset,
        preservingPresentationDataFrom candidate: WalletAsset
    ) -> WalletAsset {
        let holdingHasArtwork = holding.logoSource.bundledAssetName != nil
            || holding.logoSource.remoteLogoURL != nil
        let candidateHasArtwork = candidate.logoSource.bundledAssetName != nil
            || candidate.logoSource.remoteLogoURL != nil
        let logo = !holdingHasArtwork && candidateHasArtwork
            ? candidate.logoSource : holding.logoSource
        let address = holding.receiveAddress ?? candidate.receiveAddress
        guard logo != holding.logoSource || address != holding.receiveAddress else {
            return holding
        }
        return WalletAsset(
            id: holding.id,
            name: holding.name,
            symbol: holding.symbol,
            logoSource: logo,
            network: holding.network,
            balance: holding.balance,
            fiatValue: holding.fiatValue,
            balanceText: holding.balanceText,
            balanceAtomic: holding.balanceAtomic,
            decimals: holding.decimals,
            receiveAddress: address,
            isPinned: holding.isPinned,
            isVerified: holding.isVerified,
            isSpam: holding.isSpam
        )
    }

    private static func zeroed(
        _ candidate: WalletAsset
    ) -> WalletAsset {
        WalletAsset(
            id: candidate.id,
            name: candidate.name,
            symbol: candidate.symbol,
            logoSource: candidate.logoSource,
            network: candidate.network,
            balance: .zero,
            fiatValue: .zero,
            balanceText: "0",
            balanceAtomic: candidate.balanceAtomic == nil ? nil : "0",
            decimals: candidate.decimals,
            receiveAddress: candidate.receiveAddress,
            isPinned: candidate.isPinned,
            isVerified: candidate.isVerified,
            isSpam: candidate.isSpam
        )
    }
}

enum WalletHomeAssetCatalog {
    static func availableAssets(
        from assets: [WalletAsset],
        accountAddresses: WalletAccountAddressIndex = .empty,
        remoteCatalogAssets: [WalletAsset] =
            ReceiveAssetCatalog.walletAssets
    ) -> [WalletAsset] {
        let balanceSnapshot = WalletAssetBalanceSnapshot(assets: assets)
        var seenCatalogIDs = Set<String>()
        let mergedCatalogAssets: [WalletAsset] =
            remoteCatalogAssets.compactMap { asset -> WalletAsset? in
                let identity = AssetIdentityKey.canonical(asset.id)
                guard seenCatalogIDs.insert(identity).inserted else {
                    return nil
                }
                return balanceSnapshot.holding(matching: asset) ?? asset
            }
        let catalogIDs = Set(
            mergedCatalogAssets.map {
                AssetIdentityKey.canonical($0.id)
            }
        )
        let providerAndCustomAssets = assets.filter {
            !catalogIDs.contains(AssetIdentityKey.canonical($0.id))
        }
        let addressesByBlockchain = Dictionary(
            uniqueKeysWithValues:
                AssetNetworkSelectorOption.allSupported.compactMap {
                    option in
                    accountAddresses.address(
                        for: option.blockchain
                    ).map { (option.blockchain, $0) }
                }
        )
        return (mergedCatalogAssets + providerAndCustomAssets).map {
            assetWithPersistedAddress(
                $0,
                addressesByBlockchain: addressesByBlockchain
            )
        }
    }

    static func sortedAssets(_ assets: [WalletAsset]) -> [WalletAsset] {
        assets.sorted { first, second in
            if first.isPinned != second.isPinned {
                return first.isPinned
            }
            if first.fiatValue == second.fiatValue {
                return first.name.localizedStandardCompare(second.name)
                    == .orderedAscending
            }
            return first.fiatValue > second.fiatValue
        }
    }

    static func mainScreenAssets(
        from assets: [WalletAsset]
    ) -> [WalletAsset] {
        return resolvedAssets(
            matching: mainScreenNativeAssetIDs,
            from: assets
        )
    }

    private static func resolvedAssets(
        matching requestedAssetIDs: [String],
        from assets: [WalletAsset]
    ) -> [WalletAsset] {
        let assetsByID = Dictionary(
            assets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return requestedAssetIDs.compactMap {
            assetsByID[AssetIdentityKey.canonical($0)]
        }
    }

    private static func nativeAssetID(_ networkID: String) -> String {
        AssetIdentityKey.make(
            networkID: networkID,
            contractAddress: nil
        )
    }

    private static func assetWithPersistedAddress(
        _ asset: WalletAsset,
        addressesByBlockchain: [WalletBlockchain: String]
    ) -> WalletAsset {
        guard
            let blockchain = asset.network,
            let address = addressesByBlockchain[blockchain]
        else {
            return asset
        }
        return WalletAsset(
            id: asset.id,
            name: asset.name,
            symbol: asset.symbol,
            logoSource: asset.logoSource,
            network: blockchain,
            balance: asset.balance,
            fiatValue: asset.fiatValue,
            balanceText: asset.balanceText,
            balanceAtomic: asset.balanceAtomic,
            decimals: asset.decimals,
            receiveAddress: address,
            isPinned: asset.isPinned,
            isVerified: asset.isVerified,
            isSpam: asset.isSpam
        )
    }

    private static var mainScreenNativeAssetIDs: [String] {
        let excludedNetworkIDs: Set<String> = [
            "arbitrum",
            "avalanche",
            "base",
            "gnosis",
            "linea",
            "optimism",
            "scroll",
            "taiko",
            "telos",
            "xlayer",
            AptosConstants.networkID,
            NEARConstants.networkID,
            StellarConstants.networkID,
            SuiConstants.networkID
        ]
        let preferredNetworkIDs = [
            "eth",
            "bitcoin",
            SolanaConstants.networkID,
            "bsc",
            "tron",
            TONConstants.networkID,
            SuiConstants.networkID,
            NEARConstants.networkID,
            AptosConstants.networkID,
            StellarConstants.networkID,
            "polygon"
        ]
        let supportedNetworkIDs =
            AssetNetworkSelectorOption.allSupported.map(\.id)
        var seen = Set<String>()
        return (preferredNetworkIDs + supportedNetworkIDs)
            .compactMap { networkID -> String? in
                guard !excludedNetworkIDs.contains(networkID) else {
                    return nil
                }
                let identity = nativeAssetID(networkID)
                guard seen.insert(identity).inserted else {
                    return nil
                }
                return identity
            }
    }

}

extension AssetLogoSource {
    var localizedNativeAssetName: String? {
        guard case let .nativeCoin(blockchain) = self else { return nil }
        return WalletLocalization.string(blockchain.nativeAssetNameKey)
    }
}

extension WalletBlockchain {
    var nativeAssetNameKey: String {
        switch self {
        case .aptos: "asset.aptos.name"
        case .stellar: "asset.stellar_lumen.name"
        case .near: "asset.near.name"
        case .xrp: "asset.xrp.name"
        case .sui: "asset.sui.name"
        case .ton: "asset.gram.name"
        case .tron: "network.tron.name"
        case .solana: "network.solana.name"
        case .bitcoin: "network.bitcoin.name"
        case .bitcoincash: "network.bitcoin_cash.name"
        case .litecoin: "network.litecoin.name"
        case .dogecoin: "network.dogecoin.name"
        case .ethereum: "network.ethereum"
        case .smartchain: "network.bnb_smart_chain"
        case .polygon: "network.polygon"
        case .arbitrum: "network.arbitrum"
        case .avalanchec: "network.avalanche"
        case .optimism: "network.optimism"
        case .base: "network.base"
        case .xdai: "network.gnosis"
        case .scroll: "network.scroll"
        case .linea: "network.linea"
        case .taiko: "network.taiko"
        case .telos: "network.telos"
        case .xlayer: "network.x_layer"
        case .arc: "network.arc"
        }
    }
}
