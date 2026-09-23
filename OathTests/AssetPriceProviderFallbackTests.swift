import Foundation
import Testing
@testable import Aperture

@Suite(.serialized)
struct AssetPriceProviderFallbackTests {
    @Test
    func smallUnitPriceTruncatesToEightDecimalPlaces() throws {
        for (input, expected) in [
            ("0.000000000003152", "$0.00000000"),
            ("0.000000019", "$0.00000001"),
            ("0.009999999", "$0.00999999"),
            ("0.0012", "$0.00120000")
        ] {
            let price = try #require(Decimal(string: input))
            #expect(EnglishNumbers.unitPrice(price, using: WalletCurrencyContext(
                code: "USD", ratePerUSD: 1
            )) == expected)
        }
        #expect(EnglishNumbers.unitPrice(1, using: WalletCurrencyContext(
            code: "USD", ratePerUSD: 1
        )) == "$1.00")
    }

    @Test
    func providerDecimalAcceptsLosslessStringsAndJSONNumbers() throws {
        struct Envelope: Decodable {
            let price: AssetPriceJSONDecimal
        }
        let expected = try #require(
            Decimal(string: "1.002038720123171156829977689984")
        )
        let stringValue = try JSONDecoder().decode(
            Envelope.self,
            from: Data(
                #"{"price":"1.002038720123171156829977689984"}"#.utf8
            )
        )
        let numericValue = try JSONDecoder().decode(
            Envelope.self,
            from: Data(
                #"{"price":1.002038720123171156829977689984}"#.utf8
            )
        )

        #expect(stringValue.price.value == expected)
        #expect(numericValue.price.value == expected)
    }

    @Test
    func defiLlamaDecodesExactContractNumericPrice() async throws {
        let contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            {"coins":{"ethereum:\(contract)":{
              "price":0.9999833170466648,
              "symbol":"USDC",
              "timestamp":1788020000,
              "confidence":0.99
            }}}
            """
        )
        let price = try await AssetPriceClient.defiLlamaContractPrice(
            asset: tokenAsset(
                networkID: "eth",
                blockchain: .ethereum,
                contract: contract
            ),
            session: fixtureSession()
        )

        #expect(price == Decimal(string: "0.9999833170466648"))
        #expect(
            AssetPriceProviderURLProtocol.lastRequest()?.url?.host
                == "coins.llama.fi"
        )
    }

    @Test
    func geckoTerminalDecodesStringPriceAndSendsVersionHeader()
        async throws
    {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            {"data":{"id":"fixture","type":"simple_token_price",
              "attributes":{"token_prices":{
                "\(mint)":"1.002038720123171156829977689984"
              }}}}
            """
        )
        let price = try await AssetPriceClient.geckoTerminalContractPrice(
            asset: tokenAsset(
                networkID: "solana",
                blockchain: .solana,
                contract: mint
            ),
            session: fixtureSession()
        )
        let request = try #require(
            AssetPriceProviderURLProtocol.lastRequest()
        )

        #expect(
            price
                == Decimal(string: "1.002038720123171156829977689984")
        )
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/json;version=20230203"
        )
        #expect(request.url?.path.contains(mint) == true)
    }

    @Test
    func dexScreenerUsesExactBaseTokenAndFiltersPoolOutlier()
        async throws
    {
        let contract = "0x06efdbff2a14a7c8e15944d1f4a48f9f95f663a4"
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            [
              {"chainId":"scroll","baseToken":{"address":"\(contract)"},
               "priceUsd":"0.7515","liquidity":{"usd":91550.15}},
              {"chainId":"scroll","baseToken":{"address":"\(contract)"},
               "priceUsd":"0.9992","liquidity":{"usd":68703.58}},
              {"chainId":"scroll","baseToken":{"address":"\(contract)"},
               "priceUsd":"0.9997","liquidity":{"usd":40603.85}},
              {"chainId":"scroll","baseToken":{"address":"\(contract)"},
               "priceUsd":"1.000023","liquidity":{"usd":23951.95}},
              {"chainId":"scroll","baseToken":{"address":"0xdead"},
               "quoteToken":{"address":"\(contract)"},
               "priceUsd":"77710.56","liquidity":{"usd":9000000}},
              {"chainId":"ethereum","baseToken":{"address":"\(contract)"},
               "priceUsd":"2000","liquidity":{"usd":9000000}}
            ]
            """
        )
        let price = try await AssetPriceClient.dexScreenerContractPrice(
            asset: tokenAsset(
                networkID: "scroll",
                blockchain: .scroll,
                contract: contract
            ),
            session: fixtureSession()
        )

        #expect(price == Decimal(string: "0.9992"))
    }

    @Test
    func tonAPIDecodesExactJettonPrice() async throws {
        let contract =
            "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            {"rates":{"\(contract)":{"prices":{"USD":1.00001},
              "diff_24h":{"USD":"-0.01%"}}}}
            """
        )
        let price = try await AssetPriceClient.tonAPIContractPrice(
            asset: tokenAsset(
                networkID: "ton",
                blockchain: .ton,
                contract: contract
            ),
            session: fixtureSession()
        )

        #expect(price == Decimal(string: "1.00001"))
    }

    @Test
    func coinLoreValidatesFixedNativeIdentityBeforeUsingPrice()
        async throws
    {
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            [{"id":"36667","symbol":"tlos","name":"Telos",
              "nameid":"telos","price_usd":"0.019358"}]
            """
        )
        let price = try await AssetPriceClient.coinLoreNativePrice(
            network: .telos,
            session: fixtureSession()
        )
        #expect(price == Decimal(string: "0.019358"))

        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            [{"id":"36667","symbol":"FAKE","name":"Wrong",
              "nameid":"wrong-market","price_usd":"99"}]
            """
        )
        await expectProviderFailure(
            provider: "coinlore-native-v1",
            reason: .identityMismatch
        ) {
            try await AssetPriceClient.coinLoreNativePrice(
                network: .telos,
                session: fixtureSession()
            )
        }
    }

    @Test
    func providerHTTPStatusIsPreservedForFallbackDiagnostics()
        async throws
    {
        AssetPriceProviderURLProtocol.install(
            statusCode: 429,
            body: #"{"status":{"error_code":429}}"#
        )

        await expectProviderFailure(
            provider: "coingecko",
            reason: .httpStatus,
            statusCode: 429
        ) {
            try await AssetPriceClient.coinGeckoPrice(
                coinID: "bitcoin",
                session: fixtureSession()
            )
        }
    }

    @Test
    func malformedAndEmptySuccessResponsesRemainDistinctFailures()
        async throws
    {
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: #"{"unexpected":true}"#
        )
        await expectProviderFailure(
            provider: AssetPriceClient.defiLlamaMarketPriceProvider,
            reason: .decoding
        ) {
            try await AssetPriceClient.defiLlamaMarketPrice(
                marketID: "bitcoin",
                session: fixtureSession()
            )
        }

        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: #"{"coins":{}}"#
        )
        await expectProviderFailure(
            provider: AssetPriceClient.defiLlamaMarketPriceProvider,
            reason: .missingPrice
        ) {
            try await AssetPriceClient.defiLlamaMarketPrice(
                marketID: "bitcoin",
                session: fixtureSession()
            )
        }
    }

    @Test
    func documentedNullPricesAreMissingRatherThanMalformed() async {
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: #"{"fixture":{"usd":null}}"#
        )
        await expectProviderFailure(
            provider: "coingecko",
            reason: .missingPrice
        ) {
            try await AssetPriceClient.coinGeckoPrice(
                coinID: "fixture",
                session: fixtureSession()
            )
        }

        let contract = "0xd83af4fbd77f3ab65c3b1dc4b38d7e67aecf599a"
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            {"data":{"id":"fixture","type":"simple_token_price",
              "attributes":{"token_prices":{"\(contract)":null}}}}
            """
        )
        await expectProviderFailure(
            provider: AssetPriceClient.geckoTerminalContractPriceProvider,
            reason: .missingPrice
        ) {
            try await AssetPriceClient.geckoTerminalContractPrice(
                asset: tokenAsset(
                    networkID: "linea",
                    blockchain: .linea,
                    contract: contract
                ),
                session: fixtureSession()
            )
        }
    }

    @Test
    func nonEVMContractMatchingRemainsCaseSensitive() async throws {
        let mint = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            {"\(mint.lowercased())":{"usd":"1.25"}}
            """
        )

        await expectProviderFailure(
            provider: AssetPriceClient.exactContractPriceProvider,
            reason: .missingPrice
        ) {
            try await AssetPriceClient.coinGeckoContractPrice(
                asset: tokenAsset(
                    networkID: "solana",
                    blockchain: .solana,
                    contract: mint
                ),
                session: fixtureSession()
            )
        }
    }

    @Test
    func stellarIssuedAssetUsesItsDeterministicContractID() async throws {
        let identity =
            "USDC:GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN"
        let contractID =
            "CCW67TSZV3SSS2HXMBQ5JFGCKJNXKZM7UQUWUZPUTHXSTZLEO7SJMI75"
        let asset = tokenAsset(
            networkID: "stellar",
            blockchain: .stellar,
            contract: identity
        )
        #expect(
            AssetPriceClient.onChainProviderTokenAddress(for: asset)
                == contractID
        )
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            {"data":{"id":"fixture","type":"simple_token_price",
              "attributes":{"token_prices":{"\(contractID)":"0.9994"}}}}
            """
        )

        let price = try await AssetPriceClient.geckoTerminalContractPrice(
            asset: asset,
            session: fixtureSession()
        )

        #expect(price == Decimal(string: "0.9994"))
        #expect(
            AssetPriceProviderURLProtocol.lastRequest()?.url?.path
                .contains(contractID) == true
        )
    }

    @Test
    func xrpIssuedAssetUsesCurrencyBytesAndIssuer() async throws {
        let issuer = "rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
        let identity = "RLUSD:\(issuer)"
        let providerAddress =
            "524C555344000000000000000000000000000000.\(issuer)"
        let asset = tokenAsset(
            networkID: "xrp",
            blockchain: .xrp,
            contract: identity
        )
        #expect(
            AssetPriceClient.onChainProviderTokenAddress(for: asset)
                == providerAddress
        )
        AssetPriceProviderURLProtocol.install(
            statusCode: 200,
            body: """
            [{"chainId":"xrpl","baseToken":{"address":"\(providerAddress)"},
              "priceUsd":"0.9996","liquidity":{"usd":4653107.57}}]
            """
        )

        let price = try await AssetPriceClient.dexScreenerContractPrice(
            asset: asset,
            session: fixtureSession()
        )

        #expect(price == Decimal(string: "0.9996"))
        #expect(
            AssetPriceProviderURLProtocol.lastRequest()?.url?.path
                .contains(providerAddress) == true
        )
    }

    @Test
    func everyTokenCapableSupportedChainHasAnExactRoute() {
        let utxoChains: Set<WalletBlockchain> = [
            .bitcoin, .bitcoincash, .litecoin, .dogecoin
        ]
        for option in AssetNetworkSelectorOption.allSupported
        where !utxoChains.contains(option.blockchain) {
            let chain = option.blockchain
            #expect(
                AssetPriceClient.coinGeckoPlatformID(chain) != nil
                    || AssetPriceClient.defiLlamaChainID(chain) != nil
                    || AssetPriceClient.geckoTerminalNetworkID(chain) != nil
                    || AssetPriceClient.dexScreenerNetworkID(chain) != nil,
                "Missing exact-contract provider route for \(option.id)."
            )
        }
    }

    @Test
    func arcPricesItsNativeUSDCAndRoutesTokensThroughItsPlatform() {
        #expect(AssetPriceClient.nativeCoinGeckoID(for: .arc) == "usd-coin")
        #expect(AssetPriceClient.coinGeckoPlatformID(.arc) == "arc")
        #expect(AssetPriceClient.geckoTerminalNetworkID(.arc) == "arc")
        #expect(AssetPriceClient.dexScreenerNetworkID(.arc) == "arc")
        #expect(AssetPriceClient.defiLlamaChainID(.arc) == nil)
        #expect(AssetPriceClient.coinLoreNativeIdentity(.arc) == nil)
    }

    @Test
    func telosUsesTheLiveCanonicalMarketIdentity() {
        #expect(AssetPriceClient.nativeCoinGeckoID(for: .telos) == "telos")
        #expect(
            AssetPriceClient.coinLoreNativeIdentity(.telos)?.id == "36667"
        )
    }

    private func tokenAsset(
        networkID: String,
        blockchain: WalletBlockchain,
        contract: String
    ) -> WalletAsset {
        WalletAsset(
            id: AssetIdentityKey.make(
                networkID: networkID,
                contractAddress: contract
            ),
            name: "Fixture",
            symbol: "FIX",
            logoSource: .unavailable,
            network: blockchain,
            balance: 1,
            fiatValue: 0
        )
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            AssetPriceProviderURLProtocol.self
        ]
        return URLSession(configuration: configuration)
    }

    private func expectProviderFailure(
        provider: String,
        reason: AssetPriceProviderFailureReason,
        statusCode: Int? = nil,
        operation: () async throws -> Decimal
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected a concrete asset-price provider failure.")
        } catch let error as AssetPriceError {
            #expect(
                error == .providerFailure(
                    provider: provider,
                    reason: reason,
                    statusCode: statusCode
                )
            )
        } catch {
            Issue.record("Unexpected failure type: \(error)")
        }
    }
}

private final class AssetPriceProviderURLProtocol: URLProtocol,
    @unchecked Sendable
{
    private struct Fixture: Sendable {
        let statusCode: Int
        let body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture = Fixture(
        statusCode: 500,
        body: #"{"error":"fixture_not_installed"}"#
    )
    nonisolated(unsafe) private static var capturedRequest: URLRequest?

    static func install(statusCode: Int, body: String) {
        lock.lock()
        fixture = Fixture(statusCode: statusCode, body: body)
        capturedRequest = nil
        lock.unlock()
    }

    static func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host != nil
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.capturedRequest = request
        let fixture = Self.fixture
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
