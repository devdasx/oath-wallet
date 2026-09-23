import Foundation
import Testing
@testable import Aperture

struct AssetSearchNativeNetworkRankingTests {
    @Test
    func productionDogecoinSearchPrefersMainnetWhenValuesTie()
        throws
    {
        let assets = try nativeCatalogAssets()
        let results = WalletAssetDiscoveryIndex(
            walletAssets: assets,
            transactions: []
        ).assets(networkID: nil, searchText: "DOGE")

        let first = try #require(results.first)
        #expect(
            AssetIdentityKey.canonical(first.id)
                == AssetIdentityKey.make(
                    networkID: BitcoinFamilyChain.dogecoin.networkID,
                    contractAddress: nil
                )
        )
    }

    @Test
    func everySupportedNativeCoinWinsEqualValueSearchTies()
        throws
    {
        let catalogAssets = try nativeCatalogAssets()

        for option in AssetNetworkSelectorOption.allSupported {
            let nativeIdentity = AssetIdentityKey.make(
                networkID: option.id,
                contractAddress: nil
            )
            let native = try #require(
                catalogAssets.first {
                    AssetIdentityKey.canonical($0.id) == nativeIdentity
                },
                "Missing native asset for \(option.id)."
            )
            let alternativeNetwork = try #require(
                AssetNetworkSelectorOption.allSupported.first {
                    $0.id != option.id
                }
            )
            let alternative = nonNativeCopy(
                of: native,
                on: alternativeNetwork,
                fiatValue: 0
            )
            let index = WalletAssetDiscoveryIndex(
                walletAssets: [alternative, native],
                transactions: []
            )

            for query in Set([native.name, native.symbol]) {
                let first = try #require(
                    index.assets(
                        networkID: nil,
                        searchText: query
                    ).first,
                    "No result for \(option.id) query \(query)."
                )
                #expect(
                    AssetIdentityKey.canonical(first.id) == nativeIdentity,
                    "Native \(option.id) lost the \(query) tie to \(first.id)."
                )
            }
        }
    }

    @Test
    func higherValueAlternativeStillPrecedesMainnetCoin() throws {
        let native = WalletAsset(
            id: "bitcoin:native",
            name: "Bitcoin",
            symbol: "BTC",
            logoSource: .nativeCoin(blockchain: .bitcoin),
            network: .bitcoin,
            balance: 1,
            fiatValue: 25
        )
        let ethereum = try #require(
            AssetNetworkSelectorOption.allSupported.first {
                $0.id == "eth"
            }
        )
        let higherValueAlternative = nonNativeCopy(
            of: native,
            on: ethereum,
            fiatValue: 100
        )
        let results = WalletAssetDiscoveryIndex(
            walletAssets: [native, higherValueAlternative],
            transactions: []
        ).assets(networkID: nil, searchText: "bitcoin")

        #expect(results.map(\.id) == [higherValueAlternative.id, native.id])
    }

    @Test
    func canonicalEthereumBeatsZeroValueL2ETHWithActivity() throws {
        let assets = try nativeCatalogAssets()
        let ethereum = try #require(
            assets.first {
                AssetIdentityKey.canonical($0.id) == "eth:native"
            }
        )
        let arbitrum = try #require(
            assets.first {
                AssetIdentityKey.canonical($0.id) == "arbitrum:native"
            }
        )
        let index = WalletAssetDiscoveryIndex(
            walletAssets: [arbitrum, ethereum],
            transactions: [nativeActivity(networkID: "arbitrum")]
        )

        let first = try #require(
            index.assets(networkID: nil, searchText: "ETH").first
        )
        #expect(AssetIdentityKey.canonical(first.id) == "eth:native")
    }

    @Test
    func requestScopedSendSearchUsesTheSameValueThenNativeOrder()
        throws
    {
        let native = sendChoice(
            id: "dogecoin:native",
            networkID: "dogecoin",
            blockchain: .dogecoin,
            contractAddress: nil,
            fiatValue: 10
        )
        let token = sendChoice(
            id: "eth:dogecoin-fixture",
            networkID: "eth",
            blockchain: .ethereum,
            contractAddress: "dogecoin-fixture",
            fiatValue: 10
        )
        let higherValueToken = sendChoice(
            id: token.id,
            networkID: token.networkID,
            blockchain: token.blockchain,
            contractAddress: token.contractAddress,
            fiatValue: 50
        )

        let tied = SendAssetChoiceCatalog.filtered(
            [token, native],
            networkID: nil,
            searchText: "DOGE"
        )
        #expect(tied.map(\.id) == [native.id, token.id])

        let valueOrdered = SendAssetChoiceCatalog.filtered(
            [native, higherValueToken],
            networkID: nil,
            searchText: "DOGE"
        )
        #expect(
            valueOrdered.map(\.id) == [higherValueToken.id, native.id]
        )
    }

    /// Ranking tests provide a catalog snapshot explicitly. A fresh app's
    /// remote catalog is correctly empty until its first successful sync.
    private func nativeCatalogAssets() throws -> [WalletAsset] {
        let symbols = Dictionary(uniqueKeysWithValues:
            ReceiveNetworkCatalog.all.map { ($0.id, $0.symbol) }
                + BitcoinFamilyChain.allCases.map { ($0.networkID, $0.symbol) })
        let assets = try AssetNetworkSelectorOption.allSupported.map { network in
            WalletAsset(
                id: AssetIdentityKey.make(networkID: network.id, contractAddress: nil),
                name: network.localizedName,
                symbol: try #require(symbols[network.id]),
                logoSource: .nativeCoin(blockchain: network.blockchain),
                network: network.blockchain,
                balance: 0,
                fiatValue: 0
            )
        }
        return WalletHomeAssetCatalog.availableAssets(from: [], remoteCatalogAssets: assets)
    }

    private func nonNativeCopy(
        of native: WalletAsset,
        on network: AssetNetworkSelectorOption,
        fiatValue: Decimal
    ) -> WalletAsset {
        WalletAsset(
            id: AssetIdentityKey.make(
                networkID: network.id,
                contractAddress: "search-fixture-\(native.id)"
            ),
            name: native.name,
            symbol: native.symbol,
            logoSource: .unavailable,
            network: network.blockchain,
            balance: fiatValue > 0 ? 1 : 0,
            fiatValue: fiatValue
        )
    }

    private func sendChoice(
        id: String,
        networkID: String,
        blockchain: WalletBlockchain,
        contractAddress: String?,
        fiatValue: Decimal
    ) -> SendAssetChoice {
        SendAssetChoice(
            id: id,
            name: "Dogecoin",
            symbol: "DOGE",
            networkID: networkID,
            networkName: networkID,
            blockchain: blockchain,
            contractAddress: contractAddress,
            decimals: 8,
            logoSource: contractAddress == nil
                ? .nativeCoin(blockchain: blockchain)
                : .unavailable,
            networkLogoSource: .network(blockchain: blockchain),
            balance: fiatValue > 0 ? 1 : 0,
            fiatValue: fiatValue
        )
    }

    private func nativeActivity(networkID: String) -> WalletTransaction {
        WalletTransaction(
            id: "\(networkID)-activity",
            kind: .received(assetSymbol: "ETH"),
            detail: "",
            time: "",
            assetLogoSource: .nativeCoin(blockchain: .arbitrum),
            assetAmount: 1,
            assetSymbol: "ETH",
            fiatValue: 1,
            status: .confirmed,
            metadata: WalletTransactionMetadata(
                transactionHash: nil,
                blockchainIdentifier: networkID,
                date: Date(timeIntervalSince1970: 1),
                fromAddress: nil,
                toAddress: nil,
                blockNumber: nil,
                blockHash: nil,
                contractAddress: nil,
                tokenName: nil,
                tokenDecimals: nil,
                logIndex: nil,
                networkFee: nil,
                networkFeeFiatValue: nil,
                networkFeeSymbol: nil,
                gasPriceGwei: nil,
                gasLimit: nil,
                gasUsed: nil,
                nonce: nil,
                transactionIndex: nil,
                transactionType: nil,
                inputData: nil,
                note: nil
            )
        )
    }
}
