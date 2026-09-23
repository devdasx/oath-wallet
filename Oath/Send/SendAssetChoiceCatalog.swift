import Foundation

enum SendAssetChoiceCatalog {
    static func choice(
        for selectedAsset: WalletAsset,
        refreshedFrom walletAssets: [WalletAsset],
        capabilities: WalletCapabilities
    ) -> SendAssetChoice? {
        let selectedIdentity = AssetIdentityKey.canonical(
            selectedAsset.id
        )
        let currentAsset = walletAssets.first {
            AssetIdentityKey.canonical($0.id) == selectedIdentity
        } ?? selectedAsset

        return choices(
            from: [currentAsset],
            capabilities: capabilities
        ).first {
            $0.id == selectedIdentity
        }
    }

    static func choices(
        from walletAssets: [WalletAsset],
        capabilities: WalletCapabilities
    ) -> [SendAssetChoice] {
        choices(
            from: walletAssets,
            capabilities: capabilities,
            requestedNetworks: nil,
            requestedAsset: .unspecified
        )
    }

    static func choices(
        from walletAssets: [WalletAsset],
        capabilities: WalletCapabilities,
        for request: SendPaymentRequest
    ) -> [SendAssetChoice] {
        choices(
            from: walletAssets,
            capabilities: capabilities,
            requestedNetworks: Set(request.candidateNetworkIDs),
            requestedAsset: request.requestedAsset
        )
    }

    private static func choices(
        from walletAssets: [WalletAsset],
        capabilities: WalletCapabilities,
        requestedNetworks: Set<String>?,
        requestedAsset assetRequest: SendRequestedAsset
    ) -> [SendAssetChoice] {
        var seen = Set<String>()
        let choices = capabilities.filteredAssets(walletAssets)
            .compactMap { asset -> SendAssetChoice? in
                guard
                    let blockchain = asset.network,
                    let networkID = AssetNetworkSelectorOption.networkID(
                        for: blockchain
                    ),
                    requestedNetworks?.contains(networkID) ?? true,
                    capabilities.permits(networkID: networkID)
                else {
                    return nil
                }

                let identity = AssetIdentityKey.canonical(asset.id)
                guard seen.insert(identity).inserted else {
                    return nil
                }
                let contractAddress =
                    asset.logoSource.checksummedContractAddress
                        ?? contractFromIdentity(
                            identity,
                            networkID: networkID
                        )
                guard requestedAsset(
                    assetRequest,
                    matchesNetworkID: networkID,
                    contractAddress: contractAddress
                ) else {
                    return nil
                }
                guard let networkName = localizedNetworkName(
                    networkID: networkID,
                    blockchain: blockchain
                ) else {
                    return nil
                }

                return SendAssetChoice(
                    id: identity,
                    name: asset.name,
                    symbol: asset.symbol,
                    networkID: networkID,
                    networkName: networkName,
                    blockchain: blockchain,
                    contractAddress: contractAddress,
                    decimals: asset.decimals
                        ?? defaultDecimals(
                            blockchain: blockchain,
                            isNative: contractAddress == nil
                        ),
                    logoSource: asset.logoSource,
                    networkLogoSource: asset.networkLogoSource,
                    balance: asset.balance,
                    fiatValue: asset.fiatValue,
                    balanceAtomic: asset.balanceAtomic,
                    sourceAddress: asset.receiveAddress,
                    isVerified: asset.isVerified
                )
            }

        return choices.sorted(by: precedes)
    }

    static func filtered(
        _ choices: [SendAssetChoice],
        networkID: String?,
        searchText: String
    ) -> [SendAssetChoice] {
        let query = AssetDiscoveryRanking.normalized(searchText)
        let selectedFamily = AssetFamily.selectorFamily(for: networkID)
        let matching = choices.filter { choice in
            // A family chip offers the members and the chain's native coin
            // that pays their gas.
            let inFamilyScope = selectedFamily.map { family in
                choice.family == family
                    || (choice.isNative && choice.networkID == family.networkID)
            } ?? false
            guard networkID == nil
                || choice.networkID == networkID
                || inFamilyScope
            else {
                return false
            }
            guard !query.isEmpty else { return true }
            return AssetDiscoveryRanking.matches(
                normalizedQuery: query,
                document: searchDocument(
                    name: choice.name,
                    symbol: choice.symbol,
                    choice: choice
                )
            )
        }
        guard !query.isEmpty else { return matching }

        let choicesByIdentity = Dictionary(
            matching.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.fiatValue >= rhs.fiatValue ? lhs : rhs
            }
        )
        let rankingAssets = choicesByIdentity.values.map { choice in
            WalletAsset(
                id: choice.id,
                name: choice.name,
                symbol: choice.symbol,
                logoSource: choice.isNative
                    ? .nativeCoin(blockchain: choice.blockchain)
                    : choice.logoSource,
                network: choice.blockchain,
                balance: choice.balance,
                fiatValue: choice.fiatValue,
                isVerified: choice.isVerified
            )
        }
        return AssetDiscoveryRanking.assets(
            rankingAssets,
            transactions: [],
            searchText: searchText
        ).compactMap {
            choicesByIdentity[AssetIdentityKey.canonical($0.id)]
        }
    }

    private static func searchDocument(
        name: String,
        symbol: String,
        choice: SendAssetChoice
    ) -> AssetDiscoveryRanking.SearchDocument {
        AssetDiscoveryRanking.SearchDocument(
            name: name,
            symbol: symbol,
            networkName: choice.networkName,
            contractAddress: choice.contractAddress ?? "",
            networkID: choice.networkID,
            blockchain: choice.blockchain
        )
    }

    static func requestedAsset(
        _ requestedAsset: SendRequestedAsset,
        matchesNetworkID networkID: String,
        contractAddress: String?
    ) -> Bool {
        switch requestedAsset {
        case .unspecified:
            return true
        case .native:
            return contractAddress == nil
        case let .contract(requestedContract):
            guard let contractAddress else { return false }
            return AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: requestedContract
            ) == AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contractAddress
            )
        }
    }

    static func request(
        _ request: SendPaymentRequest,
        matches selectedAsset: SendAssetChoice
    ) -> Bool {
        request.candidateNetworkIDs.contains(selectedAsset.networkID)
            && requestedAsset(
                request.requestedAsset,
                matchesNetworkID: selectedAsset.networkID,
                contractAddress: selectedAsset.contractAddress
            )
    }

    private static func contractFromIdentity(
        _ identity: String,
        networkID: String
    ) -> String? {
        let prefix = "\(networkID.lowercased()):"
        guard identity.hasPrefix(prefix) else { return nil }
        let contract = String(identity.dropFirst(prefix.count))
        return contract.caseInsensitiveCompare("native") == .orderedSame
            ? nil
            : contract
    }

    private static func localizedNetworkName(
        networkID: String,
        blockchain: WalletBlockchain
    ) -> String? {
        if let network = ReceiveNetworkCatalog.network(
            for: networkID
        ) {
            return network.localizedName
        }
        return BitcoinFamilyChain.allCases.first(where: {
            $0.blockchain == blockchain
        })?.name
    }

    private static func defaultDecimals(
        blockchain: WalletBlockchain,
        isNative: Bool
    ) -> Int {
        guard isNative else {
            if blockchain == .xrp {
                return 15
            }
            if blockchain == .stellar {
                return StellarConstants.decimals
            }
            return 18
        }
        return switch blockchain {
        case .bitcoin, .bitcoincash, .litecoin, .dogecoin:
            8
        case .tron:
            6
        case .solana, .ton, .sui:
            9
        case .aptos:
            AptosConstants.decimals
        case .near:
            NEARConstants.decimals
        case .xrp:
            XRPConstants.decimals
        case .stellar:
            StellarConstants.decimals
        default:
            18
        }
    }

    private static func precedes(
        _ lhs: SendAssetChoice,
        _ rhs: SendAssetChoice
    ) -> Bool {
        let lhsHasBalance = lhs.balance > 0
        let rhsHasBalance = rhs.balance > 0
        if lhsHasBalance != rhsHasBalance {
            return lhsHasBalance
        }
        if lhs.fiatValue != rhs.fiatValue {
            return lhs.fiatValue > rhs.fiatValue
        }
        if lhs.isNative != rhs.isNative {
            return lhs.isNative
        }
        let lhsNetworkRank = networkRank(lhs.networkID)
        let rhsNetworkRank = networkRank(rhs.networkID)
        if lhsNetworkRank != rhsNetworkRank {
            return lhsNetworkRank < rhsNetworkRank
        }
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name)
                == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private static func networkRank(_ networkID: String) -> Int {
        AssetNetworkSelectorOption.allSupported.firstIndex(where: {
            $0.id == networkID
        }) ?? .max
    }
}
