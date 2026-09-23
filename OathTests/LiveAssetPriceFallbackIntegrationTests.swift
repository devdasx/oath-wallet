#if LIVE_MAINNET_TESTS
import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct LiveAssetPriceFallbackIntegrationTests {
    @Test
    func nativeExchangeProviderResponsesDecodeLivePrices() async throws {
        async let coinbase = AssetPriceClient.coinbasePrice(
            symbol: "BTC",
            session: Self.session()
        )
        async let coinGecko = AssetPriceClient.coinGeckoPrice(
            coinID: "bitcoin",
            session: Self.session()
        )
        async let kraken = AssetPriceClient.krakenPrice(
            symbol: "BTC",
            session: Self.session()
        )

        let prices = try await [coinbase, coinGecko, kraken]
        let lowest = try #require(prices.min())
        let highest = try #require(prices.max())
        #expect(lowest > 0)
        #expect(highest / lowest < Decimal(string: "1.2")!)
    }

    @Test
    func everySupportedNativeMarketIdentityHasAKeylessFallback()
        async throws
    {
        let marketIDs = Set(
            AssetNetworkSelectorOption.allSupported.map {
                AssetPriceClient.nativeCoinGeckoID(for: $0.blockchain)
            }
        )
        #expect(marketIDs.count == 19)

        try await withThrowingTaskGroup(of: (String, Decimal).self) {
            group in
            var iterator = marketIDs.sorted().makeIterator()
            let maximumConcurrentRequests = 4
            for _ in 0..<maximumConcurrentRequests {
                guard let marketID = iterator.next() else { break }
                group.addTask {
                    (
                        marketID,
                        try await AssetPriceClient.defiLlamaMarketPrice(
                            marketID: marketID,
                            session: Self.session()
                        )
                    )
                }
            }
            while let (marketID, price) = try await group.next() {
                #expect(price > 0, "Missing live native price for \(marketID).")
                if let next = iterator.next() {
                    group.addTask {
                        (
                            next,
                            try await AssetPriceClient.defiLlamaMarketPrice(
                                marketID: next,
                                session: Self.session()
                            )
                        )
                    }
                }
            }
        }
    }

    @Test
    func exactContractFallbacksDecodeRealIdentityFamilies() async throws {
        let defiLlamaFixtures: [WalletAsset] = [
            Self.asset(
                networkID: "aptos", network: .aptos,
                contract:
                    "0xbae207659db88bea0cbead6da0ed00aac12edcdda169e591cd41c94180b46f3b"
            ),
            Self.asset(
                networkID: "near", network: .near,
                contract: "wrap.near"
            ),
            Self.asset(
                networkID: "sui", network: .sui,
                contract:
                    "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"
            ),
            Self.asset(
                networkID: "ton", network: .ton,
                contract:
                    "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
            ),
            Self.asset(
                networkID: "solana", network: .solana,
                contract: "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
            ),
            Self.asset(
                networkID: "tron", network: .tron,
                contract: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
            ),
            Self.asset(
                networkID: "eth", network: .ethereum,
                contract: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
            ),
            Self.asset(
                networkID: "bsc", network: .smartchain,
                contract: "0x54261774905f3e6e9718f2abb10ed6555cae308a"
            ),
            Self.asset(
                networkID: "polygon", network: .polygon,
                contract: "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619"
            ),
            Self.asset(
                networkID: "arbitrum", network: .arbitrum,
                contract: "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9"
            ),
            Self.asset(
                networkID: "avalanche", network: .avalanchec,
                contract: "0x9702230a8ea53601f5cd2dc00fdbc13d4df4a8c7"
            ),
            Self.asset(
                networkID: "optimism", network: .optimism,
                contract: "0x4200000000000000000000000000000000000042"
            ),
            Self.asset(
                networkID: "base", network: .base,
                contract: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
            ),
            Self.asset(
                networkID: "gnosis", network: .xdai,
                contract: "0xe2e73a1c69ecf83f464efce6a5be353a37ca09b2"
            ),
            Self.asset(
                networkID: "scroll", network: .scroll,
                contract: "0x06efdbff2a14a7c8e15944d1f4a48f9f95f663a4"
            ),
            Self.asset(
                networkID: "linea", network: .linea,
                contract: "0x176211869ca2b568f2a7d4ee941e073a821ee1ff"
            ),
            Self.asset(
                networkID: "taiko", network: .taiko,
                contract: "0xa9d23408b9ba935c230493c40c73824df71a0975"
            ),
            Self.asset(
                networkID: "telos", network: .telos,
                contract: "0x7627b27594bc71e6ab0fce755ae8931eb1e12dac"
            ),
            Self.asset(
                networkID: "xlayer", network: .xlayer,
                contract: "0x1e4a5963abfd975d8c9021ce480b42188849d41d"
            )
        ]
        try await withThrowingTaskGroup(of: (String, Decimal).self) {
            group in
            var iterator = defiLlamaFixtures.makeIterator()
            for _ in 0..<4 {
                guard let asset = iterator.next() else { break }
                group.addTask { try await Self.defiLlamaPrice(for: asset) }
            }
            while let (assetID, price) = try await group.next() {
                #expect(
                    price > 0,
                    "Missing live exact price for \(assetID)."
                )
                if let asset = iterator.next() {
                    group.addTask {
                        try await Self.defiLlamaPrice(for: asset)
                    }
                }
            }
        }

        let ethereumUSDC = defiLlamaFixtures.first {
            $0.network == .ethereum
        }!
        #expect(
            try await AssetPriceClient.coinGeckoContractPrice(
                asset: ethereumUSDC,
                session: Self.session()
            ) > 0
        )
        let stellarUSDC = Self.asset(
            networkID: "stellar", network: .stellar,
            contract:
                "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        )
        #expect(
            try await AssetPriceClient.geckoTerminalContractPrice(
                asset: stellarUSDC,
                session: Self.session()
            ) > 0
        )
        let rippleUSD = Self.asset(
            networkID: "xrp", network: .xrp,
            contract: "RLUSD:rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
        )
        #expect(
            try await AssetPriceClient.dexScreenerContractPrice(
                asset: rippleUSD,
                session: Self.session()
            ) > 0
        )
        let tonUSDT = defiLlamaFixtures.first { $0.network == .ton }!
        #expect(
            try await AssetPriceClient.tonAPIContractPrice(
                asset: tonUSDT,
                session: Self.session()
            ) > 0
        )
        #expect(
            try await AssetPriceClient.coinLoreNativePrice(
                network: .telos,
                session: Self.session()
            ) > 0
        )
    }

    private static func defiLlamaPrice(
        for asset: WalletAsset
    ) async throws -> (String, Decimal) {
        (
            asset.id,
            try await AssetPriceClient.defiLlamaContractPrice(
                asset: asset,
                session: session()
            )
        )
    }

    private static func asset(
        networkID: String,
        network: WalletBlockchain,
        contract: String
    ) -> WalletAsset {
        WalletAsset(
            id: AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contract
            ),
            name: "Live Price Fixture",
            symbol: "FIX",
            logoSource: .unavailable,
            network: network,
            balance: 1,
            fiatValue: 0
        )
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
#endif
