import Foundation
import Testing
@testable import Aperture

struct WalletActionPresentationPreparationTests {
    private let evmAddress =
        "0x1111111111111111111111111111111111111111"
    private let bitcoinAddress =
        "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"

    @Test
    func preparationReusesOneScopedSnapshotForReceiveAndSend() async throws {
        let ethereum = asset(
            id: "eth:native",
            name: "Ether",
            symbol: "ETH",
            blockchain: .ethereum,
            address: evmAddress,
            fiatValue: 125
        )
        let bitcoin = asset(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            blockchain: .bitcoin,
            address: bitcoinAddress,
            fiatValue: 250
        )

        let preparation = await WalletActionPresentationPreparationBuilder.make(
            snapshot: WalletHomeSnapshot(
                totalBalance: 375,
                assets: [ethereum, bitcoin],
                transactions: []
            ),
            capabilities: .fullWallet,
            walletAddress: evmAddress,
            visibilityPreferencesJSON: ""
        )

        #expect(preparation.flowAssets.contains { $0.id == ethereum.id })
        #expect(preparation.flowAssets.contains { $0.id == bitcoin.id })
        #expect(
            Set(preparation.home.allAssets.map(\.id))
                .isSuperset(of: [ethereum.id, bitcoin.id])
        )
        #expect(preparation.home.transactions.isEmpty)
        #expect(
            Set(preparation.home.searchAssets.map(\.id))
                .isSuperset(of: [ethereum.id, bitcoin.id])
        )
        #expect(
            preparation.receive.walletAssets.map(\.id)
                == preparation.flowAssets.map(\.id)
        )
        #expect(
            preparation.send.initialSelections.map(\.id)
                == preparation.receive.initialSelections.map(\.id)
        )
        let sendChoiceIDs = Set(
            preparation.send.initialSelections.map(
                \.canonicalAssetIdentity
            )
        )
        #expect(
            sendChoiceIDs.contains(
                AssetIdentityKey.canonical(ethereum.id)
            )
        )
        #expect(
            sendChoiceIDs.contains(
                AssetIdentityKey.canonical(bitcoin.id)
            )
        )
    }

    @Test
    func privateKeyBitcoinPreparationScopesAndPreselectsBitcoin() async throws {
        let ethereum = asset(
            id: "eth:native",
            name: "Ether",
            symbol: "ETH",
            blockchain: .ethereum,
            address: evmAddress,
            fiatValue: 125
        )
        let bitcoin = asset(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            blockchain: .bitcoin,
            address: bitcoinAddress,
            fiatValue: 250
        )

        let preparation = await WalletActionPresentationPreparationBuilder.make(
            snapshot: WalletHomeSnapshot(
                totalBalance: 375,
                assets: [ethereum, bitcoin],
                transactions: []
            ),
            capabilities: WalletCapabilities(
                scope: .privateKey(.bitcoin)
            ),
            walletAddress: bitcoinAddress,
            visibilityPreferencesJSON: ""
        )

        #expect(
            preparation.flowAssets.allSatisfy {
                $0.network == .bitcoin
            }
        )
        #expect(
            preparation.home.allAssets.allSatisfy {
                $0.network == .bitcoin
            }
        )
        #expect(preparation.directSingleCoinAsset?.network == .bitcoin)
        #expect(
            preparation.send.walletAssets.allSatisfy {
                $0.network == .bitcoin
            }
        )
        #expect(preparation.receive.initialNetworkID == "bitcoin")
        #expect(preparation.send.initialNetworkID == "bitcoin")
    }

    @Test
    func sendInitialSelectorRejectsProviderSpamOutsideCatalog() async {
        let spamContract =
            "0x000000000000000000000000000000000000dEaD"
        let spam = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: spamContract
            ),
            name: "! Visit Example to Claim",
            symbol: "!",
            logoSource: .token(
                blockchain: .ethereum,
                checksummedContractAddress: spamContract,
                logoURL: nil,
                origin: .ankr
            ),
            network: .ethereum,
            balance: 0,
            fiatValue: 0,
            decimals: 18,
            receiveAddress: evmAddress,
            isVerified: false,
            isSpam: true
        )

        let preparation = await WalletActionPresentationPreparationBuilder.make(
            snapshot: WalletHomeSnapshot(
                totalBalance: 0,
                assets: [spam],
                transactions: []
            ),
            capabilities: .fullWallet,
            walletAddress: evmAddress,
            visibilityPreferencesJSON: "{}"
        )
        let spamIdentity = AssetIdentityKey.canonical(spam.id)

        #expect(
            !preparation.flowAssets.contains {
                AssetIdentityKey.canonical($0.id) == spamIdentity
            }
        )
        #expect(
            !preparation.send.initialSelections.contains {
                $0.canonicalAssetIdentity == spamIdentity
            }
        )
        #expect(
            preparation.send.initialSelections.map(\.id)
                == preparation.receive.initialSelections.map(\.id)
        )
    }

    @Test
    func cacheMatchRequiresRequestWalletPreferencesAndContent() async throws {
        let requestID = UUID()
        let identity = PersistedWalletIdentity(
            walletID: "wallet-1",
            address: evmAddress
        )
        let context = AppRootResolvedWalletContext(
            requestID: requestID,
            identity: identity,
            name: "Wallet",
            capabilities: .fullWallet
        )
        let stateRevision = UUID()
        let cpuPreparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: .fullWallet,
                walletAddress: evmAddress,
                visibilityPreferencesJSON: "{}"
            )
        let preparation = WalletActionPresentationPreparation(
            requestID: requestID,
            identity: identity,
            capabilities: .fullWallet,
            source: .content,
            visibilityPreferencesJSON: "{}",
            stateRevision: stateRevision,
            home: cpuPreparation.home,
            assetLists: cpuPreparation.assetLists,
            flowAssets: cpuPreparation.flowAssets,
            transactions: cpuPreparation.transactions,
            receive: cpuPreparation.receive,
            send: cpuPreparation.send,
            directSingleCoinAsset:
                cpuPreparation.directSingleCoinAsset,
            bitcoinFamilyAsset: nil
        )

        #expect(
            preparation.matches(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matches(
                presentation: .resolved(
                    context: context.replacingRequestID(UUID()),
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matches(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matches(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{\"changed\":true}"
            )
        )
        #expect(
            !preparation.matches(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context.replacingRequestID(UUID()),
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{\"changed\":true}"
            )
        )
        #expect(
            !preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context.replacingRequestID(UUID()),
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{\"changed\":true}"
            )
        )
    }

    @Test
    func loadingPreparationMatchesOnlyLoadingPresentation() async {
        let requestID = UUID()
        let identity = PersistedWalletIdentity(
            walletID: "wallet-loading",
            address: evmAddress
        )
        let context = AppRootResolvedWalletContext(
            requestID: requestID,
            identity: identity,
            name: "Wallet",
            capabilities: .fullWallet
        )
        let stateRevision = UUID()
        let cpuPreparation =
            await WalletActionPresentationPreparationBuilder.make(
                snapshot: .empty,
                capabilities: .fullWallet,
                walletAddress: evmAddress,
                visibilityPreferencesJSON: "{}"
            )
        let preparation = WalletActionPresentationPreparation(
            requestID: requestID,
            identity: identity,
            capabilities: .fullWallet,
            source: .loading,
            visibilityPreferencesJSON: "{}",
            stateRevision: stateRevision,
            home: cpuPreparation.home,
            assetLists: cpuPreparation.assetLists,
            flowAssets: cpuPreparation.flowAssets,
            transactions: cpuPreparation.transactions,
            receive: cpuPreparation.receive,
            send: cpuPreparation.send,
            directSingleCoinAsset:
                cpuPreparation.directSingleCoinAsset,
            bitcoinFamilyAsset: nil
        )

        #expect(
            preparation.matches(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matches(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesActionPresentation(
                presentation: .resolved(
                    context: context,
                    state: .loading,
                    stateRevision: UUID()
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
        #expect(
            !preparation.matchesHomeDisplay(
                presentation: .resolved(
                    context: context,
                    state: .content(.empty),
                    stateRevision: stateRevision
                ),
                visibilityPreferencesJSON: "{}"
            )
        )
    }

    private func asset(
        id: String,
        name: String,
        symbol: String,
        blockchain: WalletBlockchain,
        address: String,
        fiatValue: Decimal
    ) -> WalletAsset {
        WalletAsset(
            id: id,
            name: name,
            symbol: symbol,
            logoSource: .nativeCoin(blockchain: blockchain),
            network: blockchain,
            balance: 1,
            fiatValue: fiatValue,
            balanceText: "1",
            receiveAddress: address
        )
    }
}

struct ReceiveNativeAssetOrderingTests {
    @Test
    func everyCatalogNetworkIndexesExactlyOneNativeAsset() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        ReceiveAssetCatalogRuntime.install(
            ReceiveNetworkCatalog.all.map { ReceiveToken.nativeAsset(for: $0) }
        )
        for network in ReceiveNetworkCatalog.all {
            let nativeCandidates = ReceiveAssetSearchIndex.candidates(
                networkID: network.id
            )
            .filter {
                $0.variant.contractAddress == nil
                    && $0.variant.networkID == network.id
            }

            #expect(nativeCandidates.count == 1)
        }
    }

    @Test
    func selectedNetworkAlwaysPlacesItsNativeAssetFirst() {
        let directNativeAssets =
            AssetNetworkSelectorOption.allSupported.map {
                nativeAsset(for: $0)
            }
        let heldTokens = ReceiveNetworkCatalog.all.compactMap {
            network -> WalletAsset? in
            guard
                let selection = ReceiveAssetSearchIndex.candidates(
                    networkID: network.id
                )
                .first(where: {
                    $0.variant.contractAddress != nil
                })
            else {
                return nil
            }
            return WalletAsset(
                id: selection.variant.assetIdentity,
                name: selection.token.name,
                symbol: selection.token.symbol,
                logoSource: selection.variant.logoSource,
                network: network.blockchain,
                balance: 1,
                fiatValue: 1_000,
                decimals: selection.variant.decimals
            )
        }
        let index = CombinedAssetDiscoveryIndex(
            walletAssets: directNativeAssets + heldTokens,
            directAssets: directNativeAssets,
            transactions: []
        )

        for option in AssetNetworkSelectorOption.allSupported {
            let ranked = index.selections(
                networkID: option.id,
                searchText: ""
            )
            let visible =
                AssetDiscoverySelectionOrdering
                .orderedForSelectedNetwork(
                    ranked,
                    networkID: option.id,
                    searchText: "",
                    availableDirectAssets: directNativeAssets
                )

            guard let first = visible.first else {
                Issue.record(
                    "No Receive assets for network \(option.id)"
                )
                continue
            }
            #expect(first.isNativeAsset(for: option.id))
            #expect(
                visible.filter {
                    $0.isNativeAsset(for: option.id)
                }.count == 1
            )
        }
    }

    @Test
    func delayedDirectNativeAssetIsInjectedAfterResolution() throws {
        let bitcoinOption = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.blockchain == .bitcoin
            }
        )
        let bitcoin = nativeAsset(for: bitcoinOption)
        let visible =
            AssetDiscoverySelectionOrdering
            .orderedForSelectedNetwork(
                [],
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                searchText: "",
                availableDirectAssets: [bitcoin]
            )

        #expect(visible.count == 1)
        #expect(
            visible.first?.isNativeAsset(
                for: BitcoinFamilyChain.bitcoin.networkID
            ) == true
        )
    }

    @Test
    func searchDoesNotInjectAnUnmatchedNativeAsset() throws {
        let ethereum = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.blockchain == .ethereum
            }
        )
        let visible =
            AssetDiscoverySelectionOrdering
            .orderedForSelectedNetwork(
                [],
                networkID: ethereum.id,
                searchText: "usdt",
                availableDirectAssets: [nativeAsset(for: ethereum)]
            )

        #expect(visible.isEmpty)
    }

    private func nativeAsset(
        for option: AssetNetworkSelectorOption
    ) -> WalletAsset {
        WalletAsset(
            id: "\(option.id):native",
            name: option.localizedName,
            symbol: option.id,
            logoSource: .nativeCoin(
                blockchain: option.blockchain
            ),
            network: option.blockchain,
            balance: 0,
            fiatValue: 0,
            receiveAddress: "receive-\(option.id)"
        )
    }
}

struct ChainAwareAssetSearchTests {
    private let ethereumUSDTContract =
        "0xdAC17F958D2ee523a2206206994597C13D831ec7"
    private let bscUSDTContract =
        "0x55d398326f99059fF775485246999027B3197955"

    @Test
    func receiveSearchCombinesTokenAndEthereumTerms() {
        let previous = ReceiveAssetCatalogRuntime.snapshot
        defer { ReceiveAssetCatalogRuntime.install(previous.tokens, revision: previous.revision) }
        ReceiveAssetCatalogRuntime.install([
            ReceiveToken(id: "tether", name: "Tether USD", symbol: "USDT", rank: 3,
                         isStablecoin: true, variants: [
                ReceiveTokenVariant(networkID: "eth", contractAddress: ethereumUSDTContract,
                                    decimals: 6, networkRank: 1, logoURL: nil),
                ReceiveTokenVariant(networkID: "bsc", contractAddress: bscUSDTContract,
                                    decimals: 18, networkRank: 1, logoURL: nil)
            ])
        ])
        let queries = [
            "USDT ETH",
            "ETH USDT",
            "Tether USD ETH",
            "Tether USD Ethereum",
            "USDT Ethereum"
        ]

        for query in queries {
            let matches = ReceiveAssetSearchIndex.selections(
                matching: query
            )
            #expect(!matches.isEmpty)
            #expect(
                matches.allSatisfy {
                    $0.token.symbol == "USDT"
                        && $0.variant.networkID == "eth"
                },
                """
                Unexpected Receive result for \(query): \
                \(matches.map { "\($0.token.symbol):\($0.variant.networkID)" })
                """
            )
        }
    }

    @Test
    func walletAssetSearchSupportsNameSymbolContractAndChain() {
        let ethereum = walletAsset(
            networkID: "eth",
            contractAddress: ethereumUSDTContract
        )
        let bsc = walletAsset(
            networkID: "bsc",
            contractAddress: bscUSDTContract
        )
        let index = WalletAssetDiscoveryIndex(
            walletAssets: [ethereum, bsc],
            transactions: []
        )

        #expect(
            Set(index.assets(
                networkID: nil,
                searchText: "Tether USD"
            ).map(\.id)) == Set([ethereum.id, bsc.id])
        )
        #expect(
            Set(index.assets(
                networkID: nil,
                searchText: "USDT"
            ).map(\.id)) == Set([ethereum.id, bsc.id])
        )

        for query in [
            "ETH",
            "USDT ETH",
            "Tether USD Ethereum",
            "Ethereum USDT"
        ] {
            #expect(
                index.assets(
                    networkID: nil,
                    searchText: query
                ).map(\.id) == [ethereum.id],
                "Unexpected wallet-asset result for \(query)"
            )
        }

        #expect(
            index.assets(
                networkID: nil,
                searchText: bscUSDTContract
            ).map(\.id) == [bsc.id]
        )
    }

    @Test
    func contractSearchFallsBackToCanonicalAssetIdentity() {
        let asset = WalletAsset(
            id: AssetIdentityKey.make(
                networkID: "eth",
                contractAddress: ethereumUSDTContract
            ),
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .unavailable,
            network: .ethereum,
            balance: 0,
            fiatValue: 0
        )
        let index = WalletAssetDiscoveryIndex(
            walletAssets: [asset],
            transactions: []
        )

        #expect(
            index.assets(
                networkID: nil,
                searchText: ethereumUSDTContract
            ).map(\.id) == [asset.id]
        )
    }

    @Test
    func everySupportedMainnetAcceptsFullNameAndCommonAlias() throws {
        let commonAliasByNetworkID = [
            "aptos": "APT",
            "stellar": "XLM",
            "bitcoin": "BTC",
            "bitcoin_cash": "BCH",
            "litecoin": "LTC",
            "dogecoin": "DOGE",
            "eth": "ETH",
            "tron": "TRX",
            "solana": "SOL",
            "ton": "GRAM",
            "sui": "SUI",
            "near": "NEAR",
            "xrp": "XRPL",
            "bsc": "BSC",
            "arbitrum": "ARB",
            "base": "Base",
            "polygon": "POL",
            "optimism": "OP",
            "avalanche": "AVAX",
            "gnosis": "xDai",
            "linea": "Linea",
            "scroll": "Scroll",
            "taiko": "Taiko",
            "telos": "TLOS",
            "xlayer": "OKB"
        ]
        #expect(
            commonAliasByNetworkID.count
                == AssetNetworkSelectorOption.allSupported.count
        )

        for option in AssetNetworkSelectorOption.allSupported {
            let alias = try #require(
                commonAliasByNetworkID[option.id]
            )
            let document = AssetDiscoveryRanking.SearchDocument(
                name: "Search Fixture Token",
                symbol: "SFT",
                networkName: option.localizedName,
                contractAddress: "",
                networkID: option.id,
                blockchain: option.blockchain
            )

            for query in [
                "SFT \(option.localizedName)",
                "SFT \(alias)",
                "\(option.id) SFT"
            ] {
                #expect(
                    AssetDiscoveryRanking.matches(
                        normalizedQuery:
                            AssetDiscoveryRanking.normalized(query),
                        document: document
                    ),
                    "Unsupported network search query: \(query)"
                )
            }
        }
    }

    @Test
    func sendSearchNarrowsChoicesToTheQualifiedNetwork() throws {
        let ethereum = sendChoice(
            networkID: "eth",
            networkName: "Ethereum",
            blockchain: .ethereum,
            contractAddress: ethereumUSDTContract
        )
        let bsc = sendChoice(
            networkID: "bsc",
            networkName: "BNB Smart Chain",
            blockchain: .smartchain,
            contractAddress: bscUSDTContract
        )
        for query in [
            "USDT ETH",
            "Tether USD Ethereum",
            "Ethereum USDT"
        ] {
            #expect(
                SendAssetChoiceCatalog.filtered(
                    [ethereum, bsc],
                    networkID: nil,
                    searchText: query
                ).map(\.networkID) == ["eth"]
            )
        }

        let contractResult =
            SendAssetChoiceCatalog.filtered(
                [ethereum, bsc],
                networkID: nil,
                searchText: bscUSDTContract
            )
        #expect(contractResult.map(\.networkID) == ["bsc"])

        #expect(
            SendAssetChoiceCatalog.filtered(
                [ethereum, bsc],
                networkID: nil,
                searchText: "USDT BSC"
            ).map(\.networkID) == ["bsc"]
        )
    }

    private func walletAsset(
        networkID: String,
        contractAddress: String
    ) -> WalletAsset {
        let blockchain =
            AssetNetworkSelectorOption.blockchain(for: networkID)
                ?? .ethereum
        return WalletAsset(
            id: AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contractAddress
            ),
            name: "Tether USD",
            symbol: "USDT",
            logoSource: .catalogToken(
                blockchain: blockchain,
                contractAddress: contractAddress,
                logoURL: nil
            ),
            network: blockchain,
            balance: 0,
            fiatValue: 0
        )
    }

    private func sendChoice(
        networkID: String,
        networkName: String,
        blockchain: WalletBlockchain,
        contractAddress: String
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contractAddress
            ),
            name: "Tether USD",
            symbol: "USDT",
            networkID: networkID,
            networkName: networkName,
            blockchain: blockchain,
            contractAddress: contractAddress,
            decimals: 6,
            logoSource: .catalogToken(
                blockchain: blockchain,
                contractAddress: contractAddress,
                logoURL: nil
            ),
            networkLogoSource: .nativeCoin(
                blockchain: blockchain
            ),
            balance: 0,
            fiatValue: 0
        )
    }
}
