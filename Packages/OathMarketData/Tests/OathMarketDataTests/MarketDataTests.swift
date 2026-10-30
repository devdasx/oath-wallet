import XCTest
import OathDatabase
@testable import OathMarketData

private actor Feed: MarketTransport {
    var requests: [URL] = []
    let replies: [String: Data]
    let missing: MarketDataError
    init(_ replies: [String: String] = [:], missing: MarketDataError = .unavailable) { self.replies = replies.mapValues { Data($0.utf8) }; self.missing = missing }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        try await Task.sleep(for: .milliseconds(20))
        guard let reply = replies[url.path] else { throw missing }
        return reply
    }
    func count() -> Int { requests.count }
}

@MainActor final class MarketDataTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_740_000)
    private let eth = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)
    private let quote = #"{"data":{"amount":"2500.12345678","base":"ETH","currency":"USD"}}"#
    private let info = #"{"id":"ethereum","name":"Ethereum","symbol":"eth","description":{"en":"A <b>network</b> &amp; platform."},"links":{"homepage":["javascript:bad","https://ethereum.org/"]},"image":{"small":"https://assets.coingecko.com/coins/images/279/small/ethereum.png"}}"#

    func testFullQualityProjectImagePreferredOverSmallThumbnail() throws {
        let small = "https://assets.coingecko.com/coins/images/279/small/ethereum.png"
        let large = small.replacingOccurrences(of: "/small/", with: "/large/")
        let source = info.replacingOccurrences(of: "\"small\":\"" + small + "\"", with: "\"small\":\"" + small + "\",\"large\":\"" + large + "\"")
        XCTAssertEqual(try MarketDecoding.information(Data(source.utf8), for: eth).imageURL, large)
    }

    private func informationPayload(marketData: String) -> Data {
        Data((String(info.dropLast()) + ",\"market_data\":" + marketData + "}").utf8)
    }

    func testInformationIncludesExactMarketStatisticsForCoinsAndVerifiedTokens() throws {
        let data = informationPayload(marketData: #"{"market_cap":{"usd":1373296629498,"eur":1265825267281,"jpy":null},"total_supply":21000000,"circulating_supply":19675377.12345678}"#)
        let coin = try MarketDecoding.information(data, for: eth)
        XCTAssertEqual(coin.marketCaps?["usd"], Decimal(string: "1373296629498"))
        XCTAssertEqual(coin.marketCaps?["eur"], Decimal(string: "1265825267281"))
        XCTAssertNil(coin.marketCaps?["jpy"])
        XCTAssertEqual(coin.totalSupply, 21_000_000)
        XCTAssertEqual(coin.circulatingSupply, Decimal(string: "19675377.12345678"))
        XCTAssertEqual(try JSONDecoder().decode(AssetInformation.self, from: JSONEncoder().encode(coin)), coin)

        let token = MarketAsset(id: "ethereum:0xabc", networkID: "ethereum", reference: "0xabc", decimals: 6)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["id"] = "usd-coin"
        object["detail_platforms"] = ["ethereum": ["contract_address": "0xAbC", "decimal_place": 6]]
        let tokenData = try JSONSerialization.data(withJSONObject: object)
        let value = try MarketDecoding.information(tokenData, for: token)
        XCTAssertEqual(value.marketCaps, coin.marketCaps)
        XCTAssertEqual(value.totalSupply, coin.totalSupply)
        let wrong = MarketAsset(id: token.id, networkID: "ethereum", reference: "0xdef", decimals: 6)
        XCTAssertThrowsError(try MarketDecoding.information(tokenData, for: wrong), "Statistics cannot bypass contract identity checks")
        for asset in [eth, token] {
            let url = try MarketIdentity.informationURL(for: asset)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "market_data" }?.value, "true")
            XCTAssertEqual(query?.first { $0.name == "tickers" }?.value, "false")
        }
    }

    func testMissingStatisticsNeverBecomeInventedZeroesAndInvalidValuesAreRejected() throws {
        for payload in [Data(info.utf8), informationPayload(marketData: "null"),
                        informationPayload(marketData: #"{"market_cap":null,"total_supply":null,"circulating_supply":null}"#)] {
            let value = try MarketDecoding.information(payload, for: eth)
            XCTAssertNil(value.marketCaps); XCTAssertNil(value.totalSupply); XCTAssertNil(value.circulatingSupply)
        }
        let partial = try MarketDecoding.information(informationPayload(marketData: #"{"total_supply":0}"#), for: eth)
        XCTAssertEqual(partial.totalSupply, 0)
        XCTAssertNil(partial.circulatingSupply); XCTAssertNil(partial.marketCaps)
        for invalid in [#"{"total_supply":-1}"#, #"{"market_cap":{"usd":-1}}"#,
                        #"{"circulating_supply":"not-a-number"}"#, #"{"total_supply":true}"#] {
            XCTAssertThrowsError(try MarketDecoding.information(informationPayload(marketData: invalid), for: eth))
        }
    }

    func testStatisticsCacheUpgradesWithoutLosingOfflineDescriptionsAndRefreshesAfterFiveMinutes() async throws {
        let (db, url) = try await database()
        let now = date
        let legacy = try MarketDecoding.information(Data(info.utf8), for: eth)
        let legacyBytes = try JSONEncoder().encode(legacy)
        try await db.saveMarketCache(.init(key: "v1.info.native.ethereum", source: "CoinGecko",
            payload: legacyBytes, fetchedAt: now.timeIntervalSince1970))
        let source = String(decoding: informationPayload(marketData: #"{"market_cap":{"usd":123456789},"total_supply":21000000,"circulating_supply":19675377}"#), as: UTF8.self)
        let feed = Feed(["/api/v3/coins/ethereum": source])
        let service = MarketDataService(database: db, transport: feed, now: { now })
        let initial = try await service.cachedInformation(for: eth)
        XCTAssertEqual(initial?.value, legacy, "Existing description still loads without network")
        let upgraded = try await service.information(for: eth)
        XCTAssertEqual(upgraded.value.totalSupply, 21_000_000)
        let count = await feed.count(); XCTAssertEqual(count, 1, "A fresh description-only cache must not suppress the upgrade")

        let reopened = try await OathDatabase.open(at: url)
        let refresh = Feed(["/api/v3/coins/ethereum": source])
        let fresh = MarketDataService(database: reopened, transport: refresh, now: { now.addingTimeInterval(299) })
        let cached = try await fresh.information(for: eth)
        XCTAssertEqual(cached.value, upgraded.value)
        let freshCount = await refresh.count(); XCTAssertEqual(freshCount, 0)
        let stale = MarketDataService(database: reopened, transport: refresh, now: { now.addingTimeInterval(301) })
        _ = try await stale.information(for: eth)
        let staleCount = await refresh.count(); XCTAssertEqual(staleCount, 1)
        let offline = MarketDataService(database: reopened, transport: Feed(), now: { now.addingTimeInterval(1_000) })
        let offlineValue = try await offline.cachedInformation(for: eth)
        XCTAssertEqual(offlineValue?.value, upgraded.value, "All statistics survive reopening offline")
    }

    private func database() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oath-market-" + UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
            derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [.init(id: eth.id, networkID: "ethereum", reference: "native",
            name: "Ethereum", symbol: "ETH", decimals: 18)])
        return (db, url)
    }

    func testXrplIssuerScopedQuoteAndMetadataRemainAvailableOffline() async throws {
        let (db,url) = try await database()
        let ref = "USD.rMxCKbEDwqr76QuheSUMdEGf4B9xJ8m5De"
        try await db.seed(networks:[.init(id:"xrpl",name:"XRP Ledger",family:"account",symbol:"XRP",decimals:6,derivationPath:"fixture",logo:"",sortOrder:1)],assets:[.init(id:"xrpl:"+ref,networkID:"xrpl",reference:ref,name:"Issuer USD",symbol:"USD",decimals:96)])
        let asset = MarketAsset(id:"xrpl:"+ref,networkID:"xrpl",reference:ref,decimals:96)
        let bytes = Data("{\"reference\":\"\(ref)\",\"name\":\"Issuer USD\",\"symbol\":\"USD\",\"decimals\":96}".utf8)
        try await db.saveMarketCache(.init(key:"xrpl.token."+ref,source:"XRP Ledger",payload:bytes,fetchedAt:123))
        try await db.savePrices([.init(assetID:asset.id,currency:"USD",value:"0.998",observedAt:123,source:"CoinGecko")])
        let reopened = try await OathDatabase.open(at:url), transport = Feed()
        let service = MarketDataService(database:reopened,transport:transport)
        let info = try await service.information(for:asset), quote = try await service.quote(for:asset)
        XCTAssertEqual(info.value.name,"Issuer USD"); XCTAssertEqual(quote.value.usd,"0.998")
        XCTAssertEqual(quote.fetchedAt.timeIntervalSince1970,123)
        let calls = await transport.count(); XCTAssertGreaterThan(calls,0, "Stale persisted prices attempt refresh, retaining the original quote during outages")
        XCTAssertFalse(asset.matches(ref.lowercased()))
    }
    func testThorchainTokenDetailsReusePersistedIdentityAndQuoteOffline() async throws {
        let (db,url)=try await database()
        let ref="x/ruji", id="thorchain:x/ruji"
        try await db.seed(networks:[.init(id:"thorchain",name:"THORChain",family:"account",symbol:"RUNE",decimals:8,derivationPath:"fixture",logo:"",sortOrder:1)],assets:[.init(id:id,networkID:"thorchain",reference:ref,name:"Rujira",symbol:"RUJI",decimals:8)])
        try await db.savePrices([.init(assetID:id,currency:"USD",value:"0.2",observedAt:123,source:"THORChain markets")])
        let reopened=try await OathDatabase.open(at:url), transport=Feed()
        let service=MarketDataService(database:reopened,transport:transport)
        let asset=MarketAsset(id:id,networkID:"thorchain",reference:ref,decimals:8)
        let info=try await service.information(for:asset), quote=try await service.quote(for:asset)
        XCTAssertEqual(info.value.name,"Rujira"); XCTAssertEqual(quote.value.usd,"0.2")
        XCTAssertEqual(quote.fetchedAt.timeIntervalSince1970,123)
        let wrong=MarketAsset(id:id,networkID:"thorchain",reference:"x/unrelated",decimals:8)
        do { _ = try await service.information(for:wrong); XCTFail("wrong token identity accepted") } catch { XCTAssertEqual(error as? MarketDataError,.notListed) }
        let requests=await transport.count(); XCTAssertGreaterThan(requests,0)
    }

    func testStellarContractScopedQuoteAndMetadataRemainAvailableOffline() async throws {
        let (db,url) = try await database()
        let ref = "CCW67TSZGNEDUW6HX3O2X7GZ6GYCG7K3FSPIPCWFBQ3TG27SX3VCU5FJ"
        try await db.seed(networks:[.init(id:"stellar",name:"Stellar",family:"account",symbol:"XLM",decimals:7,derivationPath:"fixture",logo:"",sortOrder:1)],assets:[.init(id:"stellar:"+ref,networkID:"stellar",reference:ref,name:"Issuer USD",symbol:"USD",decimals:7)])
        let asset = MarketAsset(id:"stellar:"+ref,networkID:"stellar",reference:ref,decimals:7)
        let bytes = Data("{\"reference\":\"\(ref)\",\"name\":\"Issuer USD\",\"symbol\":\"USD\",\"decimals\":7}".utf8)
        try await db.saveMarketCache(.init(key:"stellar.token."+ref,source:"Stellar",payload:bytes,fetchedAt:123))
        try await db.savePrices([.init(assetID:asset.id,currency:"USD",value:"0.998",observedAt:123,source:"CoinGecko")])
        let reopened = try await OathDatabase.open(at:url), transport = Feed()
        let service = MarketDataService(database:reopened,transport:transport)
        let info = try await service.information(for:asset), quote = try await service.quote(for:asset)
        XCTAssertEqual(info.value.name,"Issuer USD"); XCTAssertEqual(quote.value.usd,"0.998")
        XCTAssertEqual(quote.fetchedAt.timeIntervalSince1970,123)
        let calls = await transport.count(); XCTAssertGreaterThan(calls,0, "Stale persisted prices attempt refresh, retaining the original quote during outages")
        XCTAssertFalse(asset.matches(ref.lowercased()))
    }

    func testTonInformationUsesPersistedContractIdentityWithoutAnotherAPIRequest() async throws {
        let (db,url) = try await database()
        let reference = "0:b113a994b5024a16719f69139328eb759596c38a25f59028b146fecdc3621dfe"
        let asset = MarketAsset(id:"ton:"+reference,networkID:"ton",reference:reference,decimals:6)
        let bytes = Data("""
        {"reference":"\(reference)","name":"Tether USD","symbol":"USD₮","decimals":6,"description":"A public Jetton description","logo":"https://example.org/token.png"}
        """.utf8)
        try await db.saveMarketCache(.init(key:"ton.token."+reference,source:"TonAPI",payload:bytes,fetchedAt:123))
        let reopened = try await OathDatabase.open(at:url), transport = Feed()
        let service = MarketDataService(database:reopened,transport:transport)
        let info = try await service.information(for:asset)
        XCTAssertEqual(info.value.name,"Tether USD");XCTAssertEqual(info.value.description,"A public Jetton description")
        XCTAssertEqual(info.value.imageURL,"https://example.org/token.png")
        let cached = try await service.cachedInformation(for:asset);XCTAssertEqual(cached?.value,info.value)
        let mismatch = MarketAsset(id:asset.id,networkID:"ton",reference:reference,decimals:9)
        let invalid = try await service.cachedInformation(for:mismatch);XCTAssertNil(invalid)
        let calls = await transport.count();XCTAssertEqual(calls,0)
        XCTAssertFalse(asset.evm)
    }

    func testAptosCoinAndFAInformationStayAvailableOffline() async throws {
        let(db,url)=try await database()
        for reference in ["0xabc::module::CaseSensitiveCoin", "0x"+String(repeating:"1",count:64)] {
            let asset=MarketAsset(id:"aptos:"+reference,networkID:"aptos",reference:reference,decimals:6)
            let bytes=Data("""
            {"reference":"\(reference)","name":"Example","symbol":"EX","decimals":6,"logo":"https://example.org/token.png","verified":true}
            """.utf8)
            try await db.saveMarketCache(.init(key:"aptos.token."+reference,source:"Aptos / Panora",payload:bytes,fetchedAt:123))
            let reopened=try await OathDatabase.open(at:url),transport=Feed()
            let service=MarketDataService(database:reopened,transport:transport)
            let info=try await service.information(for:asset)
            XCTAssertEqual(info.value.name,"Example");XCTAssertEqual(info.value.description,"")
            XCTAssertTrue(info.value.providerURL.contains(reference))
            let cached=try await service.cachedInformation(for:asset);XCTAssertEqual(cached?.value,info.value)
            let wrong=MarketAsset(id:asset.id,networkID:"aptos",reference:reference,decimals:18)
            let invalid=try await service.cachedInformation(for:wrong);XCTAssertNil(invalid)
            let calls=await transport.count();XCTAssertEqual(calls,0);XCTAssertFalse(asset.evm)
            if reference.contains("::") {XCTAssertFalse(asset.matches(reference.lowercased()))}
        }
    }

    func testSuiCoinTypeMetadataPreservesCaseAndLoadsOffline() async throws {
        let(db,url)=try await database()
        for reference in ["0xabc::module::CaseSensitiveCoin"] {
            let asset=MarketAsset(id:"sui:"+reference,networkID:"sui",reference:reference,decimals:6)
            let bytes=Data("""
            {"reference":"\(reference)","name":"Example","symbol":"EX","decimals":6,"logo":"https://example.org/token.png","verified":true}
            """.utf8)
            try await db.saveMarketCache(.init(key:"sui.token."+reference,source:"Sui on-chain metadata",payload:bytes,fetchedAt:123))
            let reopened=try await OathDatabase.open(at:url),transport=Feed()
            let service=MarketDataService(database:reopened,transport:transport)
            let info=try await service.information(for:asset)
            XCTAssertEqual(info.value.name,"Example");XCTAssertEqual(info.value.description,"")
            XCTAssertTrue(info.value.providerURL.contains(reference))
            let cached=try await service.cachedInformation(for:asset);XCTAssertEqual(cached?.value,info.value)
            let wrong=MarketAsset(id:asset.id,networkID:"sui",reference:reference,decimals:18)
            let invalid=try await service.cachedInformation(for:wrong);XCTAssertNil(invalid)
            let calls=await transport.count();XCTAssertEqual(calls,0);XCTAssertFalse(asset.evm)
            if reference.contains("::") {XCTAssertFalse(asset.matches(reference.lowercased()))}
        }
    }

    func testNearContractMetadataLoadsOfflineAndChecksDecimals() async throws {
        let (db,url) = try await database()
        let asset = MarketAsset(id:"near:wrap.near",networkID:"near",reference:"wrap.near",decimals:24)
        let bytes = Data(#"{"reference":"wrap.near","name":"Wrapped NEAR","symbol":"wNEAR","decimals":24}"#.utf8)
        try await db.saveMarketCache(.init(key:"near.token.wrap.near",source:"NEAR on-chain metadata",payload:bytes,fetchedAt:123))
        let reopened = try await OathDatabase.open(at:url), transport = Feed()
        let service = MarketDataService(database:reopened,transport:transport)
        let info = try await service.information(for:asset)
        XCTAssertEqual(info.value.symbol,"wNEAR"); XCTAssertEqual(info.value.providerURL,"https://nearblocks.io/token/wrap.near")
        let cached = try await service.cachedInformation(for:asset); XCTAssertEqual(cached?.value,info.value)
        let wrong = MarketAsset(id:asset.id,networkID:"near",reference:asset.reference,decimals:18)
        let invalid = try await service.cachedInformation(for:wrong); XCTAssertNil(invalid)
        let calls = await transport.count(); XCTAssertEqual(calls,0); XCTAssertFalse(asset.evm)
    }

    func testConcurrentQuoteReadsCoalesceAndFreshReadDoesNotRefetch() async throws {
        let (db, _) = try await database()
        let transport = Feed(["/v2/prices/ETH-USD/spot": quote])
        let now = date
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let asset = eth
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await service.quote(for: asset).value.usd } }
            var results: [String] = []
            for try await value in group { results.append(value) }
            return results
        }
        XCTAssertEqual(Set(values), ["2500.12345678"])
        _ = try await service.quote(for: eth)
        let count = await transport.count()
        XCTAssertEqual(count, 3, "Twenty readers share one request per provider; a fresh read adds none")
        let stored = try await db.latestPrice(assetID: eth.id, currency: "USD")
        XCTAssertEqual(stored?.value, "2500.12345678")
        XCTAssertEqual(stored?.source, "Coinbase")
    }

    func testQuoteInformationAndChartSurviveReopenAndProviderOutage() async throws {
        let (db, url) = try await database()
        let now = date
        let candle = "[[\(now.timeIntervalSince1970 - 7200),2400,2600,2500,2510,1],[\(now.timeIntervalSince1970 - 3600),2400,2600,2510,2520,1]]"
        let transport = Feed(["/v2/prices/ETH-USD/spot": quote, "/api/v3/coins/ethereum": info,
            "/products/ETH-USD/candles": candle, "/products/ETH-USD/stats": #"{"open":"2400","last":"2520"}"#])
        let live = MarketDataService(database: db, transport: transport, now: { now })
        let firstQuote = try await live.quote(for: eth)
        let firstInfo = try await live.information(for: eth)
        let firstChart = try await live.chart(for: eth)
        XCTAssertEqual(firstInfo.value.description, "A network & platform.")
        XCTAssertEqual(firstInfo.value.website, "https://ethereum.org/")
        XCTAssertEqual(firstChart.value.changePercent ?? 0, 5, accuracy: 0.00001)
        let reopened = try await OathDatabase.open(at: url)
        let failing = Feed()
        let offline = MarketDataService(database: reopened, transport: failing, now: { now.addingTimeInterval(90_000) })
        let retained = try await offline.quote(for: eth)
        XCTAssertEqual(retained.value, firstQuote.value)
        XCTAssertEqual(retained.fetchedAt, firstQuote.fetchedAt)
        do { _ = try await offline.information(for: eth); XCTFail("Expected outage") } catch { }
        do { _ = try await offline.chart(for: eth); XCTFail("Expected outage") } catch { }
        let savedQuote = try await offline.cachedQuote(for: eth)
        let savedInfo = try await offline.cachedInformation(for: eth)
        let savedChart = try await offline.cachedChart(for: eth)
        XCTAssertEqual(savedQuote?.value, firstQuote.value)
        XCTAssertEqual(savedQuote?.fetchedAt, now)
        XCTAssertEqual(savedInfo?.value, firstInfo.value)
        XCTAssertEqual(savedChart?.value, firstChart.value)
        let before = await failing.count()
        do { _ = try await offline.quote(for: eth, force: true) } catch { }
        let after = await failing.count()
        XCTAssertEqual(before, after, "Retry backoff must bound repeated pulls")
    }

    func testVerifiedNativeNetworksResolveIdentityAndRollupGasIsETH() throws {
        XCTAssertEqual(MarketIdentity.native.count, 41)
        XCTAssertEqual(MarketIdentity.native["polkadot"]?.gecko, "polkadot")
        XCTAssertEqual(MarketIdentity.native["polkadot"]?.coinbase, "DOT")
        XCTAssertEqual(MarketIdentity.native["thorchain"]?.gecko,"thorchain")
        XCTAssertEqual(MarketIdentity.native["thorchain"]?.coinbase,"RUNE")
        // The former CoinGecko story-2 entry now identifies Data Network.
        // Do not silently substitute that different project for Story/IP.
        XCTAssertNil(MarketIdentity.native["story"])
        for (network, identity) in MarketIdentity.native {
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: 18)
            let url = try MarketIdentity.informationURL(for: asset)
            XCTAssertEqual(url.path, "/api/v3/coins/" + identity.gecko)
            XCTAssertEqual(url.host, "api.coingecko.com")
        }
        for network in ["arbitrum", "base", "linea", "optimism", "robinhood", "scroll", "taiko"] {
            XCTAssertEqual(MarketIdentity.native[network]?.coinbase, "ETH", network)
        }
        XCTAssertEqual(MarketIdentity.native["ton"]?.coinbase, "TON")
        XCTAssertEqual(MarketIdentity.native["arc"]?.coinbase, "USDC")
        XCTAssertEqual(MarketIdentity.native["gnosis"]?.coinbase, "XDAI")
    }

    func testNativeProjectInformationIsSharedAcrossRollupNetworks() async throws {
        let (db, _) = try await database()
        let feed = Feed(["/api/v3/coins/ethereum": info])
        let service = MarketDataService(database: db, transport: feed)
        let first = try await service.information(for: eth)
        for network in ["arbitrum", "base", "linea", "optimism", "robinhood", "scroll", "taiko"] {
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: 18)
            let saved = try await service.information(for: asset)
            XCTAssertEqual(saved.value, first.value)
        }
        let count = await feed.count()
        XCTAssertEqual(count, 1, "Switching ETH networks must not exhaust the keyless project-information quota")
    }

    func testContractIdentityNeverUsesTickerAndHonorsCaseOnBase58() throws {
        let directory = Data(#"[{"id":"USDC","supported_networks":[{"id":"ethereum","contract_address":"0xAbC"},{"id":"solana","contract_address":"AbCdEf"}]},{"id":"OTHER","supported_networks":[{"id":"base","contract_address":"0xAbC"}]}]"#.utf8)
        let ethereum = MarketAsset(id: "one", networkID: "ethereum", reference: "0xabc", decimals: 6)
        let base = MarketAsset(id: "two", networkID: "base", reference: "0xabc", decimals: 6)
        XCTAssertEqual(try MarketDecoding.tokenCode(for: ethereum, directory: directory), "USDC")
        XCTAssertEqual(try MarketDecoding.tokenCode(for: base, directory: directory), "OTHER")
        let sol = MarketAsset(id: "three", networkID: "solana", reference: "abcdef", decimals: 6)
        XCTAssertThrowsError(try MarketDecoding.tokenCode(for: sol, directory: directory))
        let unknown = MarketAsset(id: "USDC", networkID: "tron", reference: "FakeUSDC", decimals: 6)
        XCTAssertThrowsError(try MarketDecoding.tokenCode(for: unknown, directory: directory))
    }

    func testWrongCurrencyCodeAndInvalidPriceAreRejected() {
        for (value, base, currency) in [("0", "ETH", "USD"), ("-1", "ETH", "USD"), ("NaN", "ETH", "USD"),
                                       ("2abc", "ETH", "USD"), ("1", "BTC", "USD"), ("1", "ETH", "EUR")] {
            let json = "{\"data\":{\"amount\":\"\(value)\",\"base\":\"\(base)\",\"currency\":\"\(currency)\"}}"
            XCTAssertThrowsError(try MarketDecoding.quote(Data(json.utf8), code: "ETH"))
        }
    }

    func testMetadataMustMatchContractAndDecimalsAndRejectUnsafeLinks() throws {
        let asset = MarketAsset(id: "token", networkID: "ethereum", reference: "0xabc", decimals: 6)
        let json = #"{"id":"usd-coin","name":"USDC","symbol":"usdc","detail_platforms":{"ethereum":{"contract_address":"0xAbC","decimal_place":6}},"links":{"homepage":["https://127.0.0.1","file:///tmp/test"]},"image":{"small":"https://untrusted.example/track.png"}}"#
        let value = try MarketDecoding.information(Data(json.utf8), for: asset)
        XCTAssertNil(value.website); XCTAssertNil(value.imageURL)
        XCTAssertThrowsError(try MarketDecoding.information(Data(json.replacingOccurrences(of: "0xAbC", with: "0xdef").utf8), for: asset))
        XCTAssertThrowsError(try MarketDecoding.information(Data(json.replacingOccurrences(of: "\"decimal_place\":6", with: "\"decimal_place\":18").utf8), for: asset))
        XCTAssertThrowsError(try MarketDecoding.information(Data(info.utf8), for: asset))
    }

    func testCandleOrderWindowAndInvalidData() throws {
        let end = date.timeIntervalSince1970
        let rows = "[[\(end-3600),2,4,3,3.5,1],[\(end-90000),1,2,1,1,1],[\(end-7200),2,4,3,3,1]]"
        let value = try MarketDecoding.chart(Data(rows.utf8), stats: nil, now: date)
        XCTAssertEqual(value.points.map(\.time), [end-7200, end-3600])
        XCTAssertNil(value.changePercent)
        XCTAssertThrowsError(try MarketDecoding.chart(Data("[[1,2,3]]".utf8), stats: nil, now: date))
        XCTAssertThrowsError(try MarketDecoding.chart(Data("[]".utf8), stats: nil, now: date))
    }

    func testTokenNotListedNeverRequestsPriceBySymbol() async throws {
        let (db, _) = try await database()
        let feed = Feed(["/currencies": #"[{"id":"USDC","supported_networks":[{"id":"ethereum","contract_address":"0xabc"}]}]"#], missing: .notListed)
        let service = MarketDataService(database: db, transport: feed)
        let fake = MarketAsset(id: "USDC", networkID: "ethereum", reference: "0xdef", decimals: 6)
        do { _ = try await service.quote(for: fake); XCTFail("Unknown token got a price") }
        catch { XCTAssertEqual(error as? MarketDataError, .notListed) }
        let paths = await feed.requests.map(\.path)
        XCTAssertEqual(paths.count, 5)
        XCTAssertFalse(paths.contains { $0.contains("USDC-USD") }, "A matching ticker never authorizes a quote for another contract")
        let cache = try await service.cachedQuote(for: fake)
        XCTAssertNil(cache)
    }
}

private actor MissingExchangeChart: MarketTransport {
    let date: Date
    var exchangeCalls = 0
    var geckoCalls = 0
    init(date: Date) { self.date = date }
    func data(from url: URL) async throws -> Data {
        if url.host == "api.exchange.coinbase.com" { exchangeCalls += 1; throw MarketDataError.notListed }
        guard url.path.hasSuffix("/market_chart") else { throw MarketDataError.invalidResponse }
        geckoCalls += 1
        return try JSONSerialization.data(withJSONObject: ["prices": [[(date.timeIntervalSince1970-3600)*1000, 0.25], [date.timeIntervalSince1970*1000, 0.275]]])
    }
}

extension MarketDataTests {
    func testTRXChartUsesAvailableMarketProviderAndPersistsOffline() async throws {
        let (db, url) = try await database(), now = date
        let feed = MissingExchangeChart(date: now), service = MarketDataService(database: db, transport: feed, now: { now })
        let trx = MarketAsset(id: "tron:native", networkID: "tron", reference: "native", decimals: 6)
        let result = try await service.chart(for: trx)
        XCTAssertEqual(result.value.points.count, 2)
        XCTAssertEqual(result.value.changePercent!, 10, accuracy: 0.0001)
        let exchange = await feed.exchangeCalls; XCTAssertEqual(exchange, 0)
        let reopened = try await OathDatabase.open(at: url)
        let offline = MarketDataService(database: reopened, transport: Feed())
        let cached = try await offline.cachedChart(for: trx)
        XCTAssertEqual(cached?.value, result.value)
    }
    func testMissingExchangeFallbackRemainsAvailableDuringPrimaryCooldown() async throws {
        let (db, _) = try await database(), now = date
        let feed = MissingExchangeChart(date: now), service = MarketDataService(database: db, transport: feed, now: { now })
        for _ in 0..<2 {
            let chart = try await service.chart(for: eth, force: true)
            XCTAssertEqual(chart.value.points.count, 2)
        }
        let gecko = await feed.geckoCalls; XCTAssertEqual(gecko, 2)
        let exchange = await feed.exchangeCalls; XCTAssertEqual(exchange, 2, "Only the first candles/stats pair can reach the absent primary listing")
    }
    func testGeckoChartRejectsInvalidAndStaleSeries() throws {
        let now = date.timeIntervalSince1970 * 1000
        for prices in [[[now, -1], [now+1, 2]], [[1.0, 2], [2, 3]], [[now, 2, 3]]] {
            let data = try JSONSerialization.data(withJSONObject: ["prices": prices])
            XCTAssertThrowsError(try MarketDecoding.geckoChart(data, now: date))
        }
    }
}
