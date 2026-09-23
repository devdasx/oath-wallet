#if LIVE_MAINNET_TESTS
import CryptoKit
import Foundation
import Testing
import WalletCore
@testable import Aperture
@Suite(.serialized)
struct LiveTONMainnetProviderIntegrationTests {
    @Test
    func activeAccountPublishesBalancesAndHistory() async throws {
        let address =
            "UQBm--PFwDv1yCeS-QTJ-L8oiUpqo9IT1BwgVptlSq3ts4DV"
        let raw = try #require(TONAddress.rawAddress(from: address))
        let snapshot = try await TONAPIClient.shared.loadSnapshot(
            material: TONAccountMaterial(
                address: address,
                rawAddress: raw,
                bounceableAddress: try #require(
                    TONAddress.userFriendlyAddress(
                        from: raw,
                        bounceable: true
                    )
                ),
                publicKey: "live-public-fixture",
                derivationPath: nil
            )
        )
        #expect(snapshot.jettonsAreAuthoritative)
        #expect(snapshot.eventsAreAuthoritative)
        #expect(Decimal(string: snapshot.nativeAmountText) != nil)
        #expect(!snapshot.history.isEmpty)
    }
}

@Suite(.serialized)
struct LiveTRONMainnetProviderIntegrationTests {
    @Test
    func resolvesUSDTContractMetadata() async throws {
        let network = try #require(
            ReceiveNetworkCatalog.network(for: TronConstants.networkID)
        )
        let token = try await TronAPIClient.shared.lookupToken(
            network: network,
            contractAddress: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
        )

        #expect(token.name == "Tether USD")
        #expect(token.symbol == "USDT")
        #expect(token.decimals == 6)
    }

    @Test
    func activeAccountPublishesBalancesAndHistory() async throws {
        let address = "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
        let snapshot = try await TronAPIClient.shared.loadSnapshot(
            material: TronAccountMaterial(
                address: address,
                hexAddress: try #require(
                    TronValueParser.accountHexAddress(address)
                ),
                publicKey: "live-public-fixture"
            ),
            trackedTokens: []
        )
        #expect(snapshot.trxBalance >= 0)
        #expect(snapshot.providerFailures.isEmpty)
        #expect(!snapshot.history.isEmpty)
    }
}

@Suite(.serialized)
struct LiveSolanaMainnetProviderIntegrationTests {
    @Test
    func consolidatedBalanceBatchLoadsEveryAccount() async throws {
        let first = SolanaAccountMaterial(
            kind: .trustWallet,
            address: "D89hHJT5Aqyx1trP6EnGY9jJUB3whgnq3aUvvCqedvzf",
            publicKey: "live-public-fixture",
            derivationPath: SolanaDerivationKind.trustWallet.derivationPath
        )
        let second = SolanaAccountMaterial(
            kind: .phantom,
            address: "11111111111111111111111111111111",
            publicKey: "live-public-fixture",
            derivationPath: SolanaDerivationKind.phantom.derivationPath
        )
        let coldStarted = ContinuousClock.now
        let coldSnapshot = try await SolanaAPIClient.shared.loadBalanceSnapshot(
            accounts: SolanaAccountSet(
                primary: first,
                alternatives: [second]
            ),
            historyCursors: [:]
        )
        let coldElapsed = coldStarted.duration(to: .now)
        print(
            "[BalanceBenchmark] solana 2 accounts/6 calls cold: "
                + "\(coldElapsed)"
        )

        let warmStarted = ContinuousClock.now
        let warmSnapshot = try await SolanaAPIClient.shared.loadBalanceSnapshot(
            accounts: SolanaAccountSet(
                primary: first,
                alternatives: [second]
            ),
            historyCursors: [:]
        )
        let warmElapsed = warmStarted.duration(to: .now)
        print(
            "[BalanceBenchmark] solana 2 accounts/6 calls warm: "
                + "\(warmElapsed)"
        )

        #expect(coldSnapshot.addressSnapshots.count == 2)
        #expect(warmSnapshot.addressSnapshots.count == 2)
        #expect(coldSnapshot.addressSnapshots.allSatisfy {
            $0.balanceAuthority.isComplete
        })
        #expect(warmSnapshot.addressSnapshots.allSatisfy {
            $0.balanceAuthority.isComplete
        })
    }

    @Test
    func resolvesUSDCMintAgainstMetadataAndOnChainAccount() async throws {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        let network = try #require(
            ReceiveNetworkCatalog.network(for: SolanaConstants.networkID)
        )
        let token = try await SolanaTokenEligibilityClient.shared
            .lookupToken(network: network, mint: mint)

        #expect(token.name == "USD Coin")
        #expect(token.symbol == "USDC")
        #expect(token.decimals == 6)
        #expect(token.eligibility.isVerified)
    }

    @Test
    func activeAccountPublishesBalancesAndHistory() async throws {
        let address = "D89hHJT5Aqyx1trP6EnGY9jJUB3whgnq3aUvvCqedvzf"
        let material = SolanaAccountMaterial(
            kind: .trustWallet,
            address: address,
            publicKey: "live-public-fixture",
            derivationPath: SolanaDerivationKind.trustWallet.derivationPath
        )
        let snapshot = try await SolanaAPIClient.shared.loadSnapshot(
            accounts: SolanaAccountSet(primary: material, alternatives: []),
            historyCursors: [:]
        )
        let account = try #require(snapshot.addressSnapshots.first)
        #expect(account.balanceAuthority.isComplete)
        #expect(account.solBalance >= 0)
        #expect(!snapshot.history.isEmpty)
    }
}

@Suite(.serialized)
struct LiveNEARMainnetProviderIntegrationTests {
    @Test
    func activeAccountPublishesBalancesAndHistory() async throws {
        let snapshot = try await NEARAPIClient.shared.loadSnapshot(
            material: NEARAccountMaterial(
                address: "wrap.near",
                publicKey: "live-public-fixture",
                derivationPath: nil
            )
        )
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(!snapshot.balances.isEmpty)
        #expect(!snapshot.history.isEmpty)
    }
}

@Suite(.serialized)
struct LiveAptosMainnetProviderIntegrationTests {
    @Test
    func officialIndexerReturnsUniqueCanonicalPrimaryBalances() async throws {
        let owner =
            "0x921c03f26b568dddb63efaab380b42c295472787bcaef7adb37af8882d0bb195"
        let page: AptosIndexerBalancesResponse = try await AptosIndexerTransport(
            router: AdaptiveProviderRouter()
        ).request(
            query: AptosAPIClient.balancesQuery,
            variables: [
                "owner": .string(owner),
                "limit": .integer(10),
                "afterAsset": .string("")
            ]
        )
        #expect(!page.currentFungibleAssetBalances.isEmpty)
        let everyBalanceIsPrimary = page.currentFungibleAssetBalances
            .map(\.isPrimary)
            .allSatisfy { $0 }
        #expect(everyBalanceIsPrimary)

        let storageIDs = try page.currentFungibleAssetBalances.map { item in
            try #require(AptosAddress.canonical(item.storageID))
        }
        #expect(storageIDs == page.currentFungibleAssetBalances.map(\.storageID))
        #expect(Set(storageIDs).count == storageIDs.count)

        let assetTypes = page.currentFungibleAssetBalances.map(\.assetType)
        #expect(assetTypes == assetTypes.sorted())
        #expect(Set(assetTypes).count == assetTypes.count)
        #expect(
            assetTypes.allSatisfy {
                AptosAssetType.canonical($0) != nil
            }
        )
        #expect(
            page.currentFungibleAssetBalances.allSatisfy {
                ExactDecimalText.canonicalUnsignedInteger($0.amount) != nil
            }
        )
    }

    @Test
    func activeAccountPublishesBalancesAndHistory() async throws {
        let address =
            "0x83d019423e9d9ca6365c2cc0bc4b4b59eb66317d59e6697c869e14c75dc75619"
        let startedAt = ContinuousClock.now
        let snapshot = try await AptosAPIClient.shared.loadSnapshot(
            material: AptosAccountMaterial(
                address: address,
                publicKey: "live-public-fixture",
                derivationPath: nil
            )
        )
        let native = try #require(
            snapshot.balances.first(where: {
                $0.metadata.assetType == AptosConstants.nativeCoinType
            })
        )
        #expect(UInt64(native.atomicAmount) != nil)
        #expect(
            Decimal(
                string: native.amountText,
                locale: Locale(identifier: "en_US_POSIX")
            ) != nil
        )
        #expect(startedAt.duration(to: .now) < .seconds(12))

        // The anonymous public GraphQL indexer is not a dependable source:
        // it can be unavailable while fullnode REST remains healthy. In that
        // case the client must publish the verified native balance promptly,
        // label token/history data non-authoritative, and preserve a concrete
        // provider failure instead of claiming an empty account.
        if !snapshot.balancesAreAuthoritative {
            #expect(!snapshot.providerFailureCodes.isEmpty)
        }
        if snapshot.history.isEmpty {
            #expect(!snapshot.historyIsAuthoritative)
        }
    }
}

@Suite(.serialized)
struct LiveStellarMainnetProviderIntegrationTests {
    @Test
    func activeAccountPublishesBalancesAndHistory() async throws {
        let address =
            "GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        let snapshot = try await StellarAPIClient.shared.loadSnapshot(
            material: StellarAccountMaterial(
                address: address,
                publicKey: "live-public-fixture",
                derivationPath: nil
            )
        )
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        #expect(!snapshot.balances.isEmpty)
        #expect(!snapshot.history.isEmpty)
    }
}

@Suite(.serialized)
struct LiveXRPMainnetProviderIntegrationTests {
    @Test
    func activeTokenHoldingAccountPublishesBalancesPromptly() async throws {
        let startedAt = ContinuousClock.now
        let probe = BalancePublicationProbe()
        let snapshot = try await XRPAPIClient.shared.loadSnapshot(
            material: XRPAccountMaterial(
                address: "rMwNibdiFaEzsTaFCG1NnmAM3Rv3vHUy5L",
                publicKey: "live-public-fixture",
                derivationPath: nil
            )
        ) { partial in
            await probe.record(
                partial,
                elapsed: startedAt.duration(to: .now)
            )
        }
        #expect(snapshot.balancesAreAuthoritative)
        #expect(snapshot.providerFailureCodes.isEmpty)
        let native = try #require(
            snapshot.balances.first(where: { $0.isNative })
        )
        #expect(XRPAmount.isPositive(native.amountText))
        let issued = try #require(
            snapshot.balances.first(where: { !$0.isNative })
        )
        #expect(XRPAmount.isPositive(issued.amountText))
        #expect(
            snapshot.balances.contains {
                $0.metadata?.identity
                    == "RLUSD:rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
            }
        )

        let nativeLatency = try #require(await probe.nativeLatency)
        let issuedLatency = try #require(await probe.issuedLatency)
        #expect(nativeLatency < .seconds(5))
        #expect(issuedLatency < .seconds(5))
    }

    private actor BalancePublicationProbe {
        private(set) var nativeLatency: Duration?
        private(set) var issuedLatency: Duration?

        func record(_ snapshot: XRPWalletSnapshot, elapsed: Duration) {
            if nativeLatency == nil,
               snapshot.balances.contains(where: \.isNative) {
                nativeLatency = elapsed
            }
            if issuedLatency == nil,
               snapshot.balances.contains(where: { !$0.isNative }) {
                issuedLatency = elapsed
            }
        }
    }
}

@Suite(.serialized)
struct LiveAssetPriceProviderIntegrationTests {
    private struct Quote: Decodable {
        let usd: Decimal
    }

    @Test
    func everySupportedNativeAndCuratedFallbackHasALiveUSDQuote()
        async throws
    {
        let nativeAssets = AssetNetworkSelectorOption.allSupported.map {
            network in
            WalletAsset(
                id: AssetIdentityKey.make(
                    networkID: network.id,
                    contractAddress: nil
                ),
                name: network.id,
                symbol: network.id,
                logoSource: .nativeCoin(
                    blockchain: network.blockchain
                ),
                network: network.blockchain,
                balance: 1,
                fiatValue: 0
            )
        }
        let marketIDs = Set(
            (nativeAssets + ReceiveAssetCatalog.walletAssets).compactMap {
                AssetPriceClient.coinGeckoMarketID(for: $0)
            }
        )
        #expect(marketIDs.count >= 37)

        var components = URLComponents(
            string: "https://api.coingecko.com/api/v3/simple/price"
        )
        components?.queryItems = [
            URLQueryItem(
                name: "ids",
                value: marketIDs.sorted().joined(separator: ",")
            ),
            URLQueryItem(name: "vs_currencies", value: "usd"),
            URLQueryItem(name: "precision", value: "full")
        ]
        let url = try #require(components?.url)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Aperture-Live-Price-Test/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let (data, response) = try await URLSession(
            configuration: configuration
        ).data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        guard http.statusCode == 200 else {
            Issue.record(
                "CoinGecko live price matrix returned HTTP \(http.statusCode)."
            )
            return
        }
        let quotes = try JSONDecoder().decode(
            [String: Quote].self,
            from: data
        )
        for marketID in marketIDs.sorted() {
            let quote = try #require(
                quotes[marketID],
                "Missing live USD quote for \(marketID)."
            )
            #expect(quote.usd > 0)
        }
    }
}

@Suite
struct BitcoinFamilyRepeatLiveTests {
    @Test
    func importedBitcoinIdentityResolvesARealMainnetRecipient()
        async throws
    {
        let transactionHash =
            "8dc27dd25aa3fc9833fc26de2b31c68bc48e213ccc94864c8d8f0b1002feafe8"
        let sender = "bc1qkr0exhjzejyxjm0hqesaafgh3yc92ghkhtkkxa"
        let recipient = "bc1qzgxlvecffk4cq3my45t2uawphfmwterptkcehr"

        let identity = try await BitcoinFamilyIndexedAPIClient.shared
            .transactionIdentity(
                chain: .bitcoin,
                transactionHash: transactionHash,
                walletAddress: sender,
                direction: "outgoing"
            )

        #expect(identity.fromAddress == sender)
        #expect(identity.toAddress == recipient)
    }
}
#endif
