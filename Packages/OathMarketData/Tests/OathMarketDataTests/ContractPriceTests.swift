import XCTest
import OathDatabase
import OathAnkr
@testable import OathMarketData

@MainActor final class ContractPriceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let token = MarketAsset(id: "ethereum:0xabc", networkID: "ethereum", reference: "0xabc", decimals: 6)
    private func decode(_ json: String, _ provider: ContractPriceRequest.Provider, asset: MarketAsset? = nil) throws -> ResolvedMarketPrice {
        let asset = asset ?? token
        let request = ContractPriceRequest.requests(for: asset).first { $0.provider == provider }!
        return try ContractPriceDecoding.decode(Data(json.utf8), request: request, asset: asset, now: now)
    }
    func testEverySupportedTokenNetworkHasContractProviders() {
        let supported: Set<String> = ["ethereum","arbitrum","arc","avalanche","base","bnb","fantom","flare","gnosis","linea","optimism","polygon","monad","unichain","hyperevm","robinhood","scroll","somnia","story","taiko","telos","xlayer","solana","tron","ton","aptos","sui","near","xrpl","stellar","thorchain"]
        XCTAssertEqual(Set(ContractPriceRequest.terminalNetworks.keys), supported)
        for network in supported {
            let asset = MarketAsset(id:network+":fixture",networkID:network,reference:"fixture",decimals:6)
            let requests = ContractPriceRequest.requests(for:asset)
            XCTAssertGreaterThanOrEqual(requests.count,3,network)
            XCTAssertTrue(requests.allSatisfy { $0.url.scheme == "https" && $0.url.user == nil && $0.url.password == nil })
        }
        // A missing native project mapping must not request a token named native.
        XCTAssertTrue(ContractPriceRequest.requests(for:.init(id:"story:native",networkID:"story",reference:"native",decimals:18)).isEmpty)
    }
    func testExactContractRequiredAndBase58RemainsCaseSensitive() throws {
        let valid = #"{"0xABC":{"usd":0.998,"last_updated_at":1800000000}}"#
        XCTAssertEqual(try decode(valid,.gecko).quote.usd,"0.998")
        XCTAssertThrowsError(try decode(valid.replacingOccurrences(of:"0xABC",with:"0xdef"),.gecko))
        let sol = MarketAsset(id:"solana:CaseSensitive",networkID:"solana",reference:"CaseSensitive",decimals:9)
        XCTAssertThrowsError(try decode(#"{"casesensitive":{"usd":1,"last_updated_at":1800000000}}"#,.gecko,asset:sol))
        XCTAssertThrowsError(try decode(#"{"0xabc":{"usd":1,"last_updated_at":1799998000}}"#,.gecko))
        XCTAssertThrowsError(try decode(#"{"0xabc":{"usd":1,"last_updated_at":1800000200}}"#,.gecko))
    }
    func testInvalidAmountsNeverBecomePrices() throws {
        for amount in ["true","false","0","-1","\"NaN\"","\"Infinity\"","\" 1\"","\"1 USD\""] {
            XCTAssertThrowsError(try decode("{\"0xabc\":{\"usd\":\(amount),\"last_updated_at\":1800000000}}",.gecko),amount)
        }
        XCTAssertEqual(try decode(#"{"0xabc":{"usd":"0.00000000000123","last_updated_at":1800000000}}"#,.gecko).quote.usd,"0.00000000000123")
    }
    func testLlamaRequiresMatchingChainConfidenceDecimalsAndTimestamp() throws {
        let json = #"{"coins":{"ethereum:0xabc":{"price":1.03,"timestamp":1800000000,"confidence":0.99,"decimals":6}}}"#
        XCTAssertEqual(try decode(json,.llama).quote.usd,"1.03")
        for bad in [json.replacingOccurrences(of:"ethereum:",with:"base:"),json.replacingOccurrences(of:"0.99",with:"0.5"),json.replacingOccurrences(of:"\"decimals\":6",with:"\"decimals\":18"),json.replacingOccurrences(of:"1800000000",with:"1799998000")] {
            XCTAssertThrowsError(try decode(bad,.llama))
        }
    }
    func testTerminalRequiresExactNetworkIdentityDecimalsAndLiquidity() throws {
        let json = #"{"data":{"id":"eth_0xabc","attributes":{"address":"0xabc","price_usd":"2.5","decimals":6,"total_reserve_in_usd":"100000.125"}}}"#
        XCTAssertEqual(try decode(json,.terminal).quote.usd,"2.5")
        for bad in [json.replacingOccurrences(of:"eth_",with:"base_"),json.replacingOccurrences(of:"100000.125",with:"1"),json.replacingOccurrences(of:"\"decimals\":6",with:"\"decimals\":18")] {
            XCTAssertThrowsError(try decode(bad,.terminal))
        }
    }
    func testDexUsesOnlyExactBaseAndChainAndDeepestPool() throws {
        let json = #"{"pairs":[{"chainId":"ethereum","baseToken":{"address":"0xdef"},"quoteToken":{"address":"0xabc"},"priceUsd":"900","liquidity":{"usd":99999999}},{"chainId":"base","baseToken":{"address":"0xabc"},"priceUsd":"100","liquidity":{"usd":99999999}},{"chainId":"ethereum","baseToken":{"address":"0xabc"},"priceUsd":"3","liquidity":{"usd":1000}},{"chainId":"ethereum","baseToken":{"address":"0xabc"},"priceUsd":"2.5","liquidity":{"usd":99999}}]}"#
        XCTAssertEqual(try decode(json,.dex).quote.usd,"2.5")
        XCTAssertThrowsError(try decode(#"{"pairs":null}"#,.dex))
        XCTAssertThrowsError(try decode(#"{"pairs":[]}"#,.dex))
    }
    func testChainSpecificCanonicalizationAndURLReferences() throws {
        let ton = MarketAsset(id:"fixture",networkID:"ton",reference:"0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe",decimals:6)
        XCTAssertTrue(ContractPriceDecoding.matches(try TonIdentity.friendly(ton.reference),asset:ton))
        let move = MarketAsset(id:"fixture",networkID:"aptos",reference:"0x1::coin::Coin",decimals:8)
        XCTAssertTrue(ContractPriceDecoding.matches("0x0001::coin::Coin",asset:move))
        XCTAssertFalse(ContractPriceDecoding.matches("0x1::coin::coin",asset:move))
        let bank = MarketAsset(id:"fixture",networkID:"thorchain",reference:"x/unknown",decimals:8)
        let url = ContractPriceRequest.requests(for:bank).first!.url.absoluteString
        XCTAssertTrue(url.contains("x%2Funknown"))
    }
    func testThorchainKnownBankDenominationUsesExactProjectMapping() throws {
        let ruji = MarketAsset(id:"thorchain:x/ruji",networkID:"thorchain",reference:"x/ruji",decimals:8)
        XCTAssertEqual(try decode(#"{"rujira":{"usd":0.15,"last_updated_at":1800000000}}"#,.gecko,asset:ruji).quote.usd,"0.15")
        XCTAssertThrowsError(try decode(#"{"another-project":{"usd":0.15,"last_updated_at":1800000000}}"#,.gecko,asset:ruji))
    }
    func testRacePublishesSuccessWithoutWaitingForSlowProviderAndSurvivesFailure() async throws {
        let expected = ResolvedMarketPrice(quote:.init(code:"token",usd:"2.5"),date:now,source:"fixture")
        let start = ContinuousClock.now
        let value = try await ParallelMarketPrice.first([
            .init(source:"down",fetch:{throw MarketDataError.rateLimited}),
            .init(source:"slow",fetch:{ try await Task.sleep(for:.seconds(2)); return expected }),
            .init(source:"fast",fetch:{try await Task.sleep(for:.milliseconds(20));return expected})
        ],network:"ethereum")
        XCTAssertEqual(value.quote.usd,"2.5")
        XCTAssertLessThan(start.duration(to:.now),.seconds(1))
    }
    func testRaceTimeoutAndCancellationAreBounded() async throws {
        let hanging = ParallelMarketPrice.Candidate(source:"slow") {
            try await Task.sleep(for:.seconds(20)); throw MarketDataError.notListed
        }
        do { _ = try await ParallelMarketPrice.first([hanging],network:"solana",timeout:.milliseconds(20)); XCTFail() }
        catch { XCTAssertEqual(error as? MarketDataError,.unavailable) }
        let task = Task { try await ParallelMarketPrice.first([hanging],network:"solana") }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor ContractFixtureFeed: MarketTransport {
    var calls = 0
    func data(from url: URL) async throws -> Data {
        calls += 1
        guard url.host == "api.dexscreener.com" else { throw MarketDataError.rateLimited }
        return Data(#"{"pairs":[{"chainId":"bsc","baseToken":{"address":"0xabc"},"priceUsd":"0.00001234","liquidity":{"usd":100000}}]}"#.utf8)
    }
}

extension ContractPriceTests {
    func testIndependentContractQuotePersistsAndReopensForHomeWhenPrimaryProvidersFail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("contract-price-test-"+UUID().uuidString)
        let url = directory.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at:url)
        try await db.seed(networks:[.init(id:"bnb",name:"BNB Smart Chain",family:"evm",symbol:"BNB",decimals:18,derivationPath:"fixture",logo:"",sortOrder:0)],
            assets:[.init(id:"bnb:0xabc",networkID:"bnb",reference:"0xabc",name:"Token",symbol:"TOKEN",decimals:6)])
        let asset=MarketAsset(id:"bnb:0xabc",networkID:"bnb",reference:"0xabc",decimals:6)
        let feed=ContractFixtureFeed(), date=now
        let service=MarketDataService(database:db,transport:feed,now:{date})
        let fresh = try await service.quote(for:asset)
        XCTAssertEqual(fresh.value.usd,"0.00001234")
        let price = try await db.latestPrice(assetID:asset.id,currency:"USD")
        XCTAssertEqual(price?.source,"DEX Screener")
        XCTAssertEqual(price?.value,fresh.value.usd)
        let before=await feed.calls
        _ = try await service.quote(for:asset)
        let after=await feed.calls
        XCTAssertEqual(before,after,"Fresh prices must not issue another provider request")
        let reopened=try await OathDatabase.open(at:url)
        let offline=MarketDataService(database:reopened,transport:feed,now:{date.addingTimeInterval(500)})
        let saved=try await offline.cachedQuote(for:asset)
        XCTAssertEqual(saved?.value,fresh.value)
        XCTAssertEqual(saved?.fetchedAt,date)
        let other=MarketAsset(id:"base:0xabc",networkID:"base",reference:"0xabc",decimals:6)
        let wrongChain = try await offline.cachedQuote(for:other)
        XCTAssertNil(wrongChain)
        // A separate balance synchronizer can publish a newer observation.
        // Refreshing a slower market provider must preserve that newer price.
        try await db.savePrices([.init(assetID:asset.id,currency:"USD",value:"0.000013",observedAt:date.timeIntervalSince1970+10,source:"chain synchronizer")])
        let retained = try await service.quote(for:asset,force:true)
        XCTAssertEqual(retained.value.usd,"0.000013")
        XCTAssertEqual(retained.fetchedAt,date.addingTimeInterval(10))
    }
}
