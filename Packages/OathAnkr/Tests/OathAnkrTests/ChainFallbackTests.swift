import Foundation
import XCTest
@testable import OathAnkr

private actor RoutingFixture: AnkrTransport {
    var requests:[URLRequest]=[]
    let handler:@Sendable (URLRequest) throws -> (Data,Int)
    init(_ handler:@escaping @Sendable (URLRequest) throws -> (Data,Int)) { self.handler=handler }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request)
        try await Task.sleep(for:.milliseconds(5))
        return try handler(request)
    }
}

final class ChainFallbackTests:XCTestCase,@unchecked Sendable {
    func testAptosArchiveOutageRotatesToAnkrForRecentReceipt() async throws {
        let transport=RoutingFixture { request in
            request.url!.host == "archive.mainnet.aptoslabs.com" ? (Data(),503):(Data(#"{"version":"123"}"#.utf8),200)
        }
        let result=try await AptosClient(testTransport:transport).node("transactions/by_version/123")
        XCTAssertEqual(result["version"].text,"123")
        let requests=await transport.requests
        XCTAssertEqual(requests.map{$0.url!.host!},["archive.mainnet.aptoslabs.com","rpc.ankr.com"])
    }
    func testAptosPrunedStateSkipsOtherPrunedNodeAndPreservesVersionAndBody() async throws {
        let transport=RoutingFixture { request in
            request.url!.host == "rpc.ankr.com" ? (Data(),410):(Data("[\"10\"]".utf8),200)
        }
        let result=try await AptosClient(testTransport:transport).node("view",version:100,body:.object(["function":.string("fixture")]))
        XCTAssertEqual(result.array?.first?.text,"10")
        let requests=await transport.requests
        XCTAssertEqual(requests.map{$0.url!.host!},["rpc.ankr.com","archive.mainnet.aptoslabs.com"])
        XCTAssertEqual(requests[1].httpBody,requests[0].httpBody)
        XCTAssertEqual(requests[1].url!.query,"ledger_version=100")
        XCTAssertNil(requests[1].value(forHTTPHeaderField:"Authorization"))
        XCTAssertFalse(requests[1].url!.path.contains("fixture"))
    }
    func testAptosOutageIsFailureAndCancellationDoesNotTryMoreProviders() async throws {
        let outage=RoutingFixture { _ in (Data(),503) }
        do { _=try await AptosClient(testTransport:outage).node("transactions/by_version/123");XCTFail() }
        catch { XCTAssertEqual(error as? AptosError,.http(503)) }
        let calls=await outage.requests.count;XCTAssertEqual(calls,3)
        let cancelled=RoutingFixture { _ in throw CancellationError() }
        do { _=try await AptosClient(testTransport:cancelled).node("");XCTFail() }
        catch is CancellationError { }
        let cancelledCalls=await cancelled.requests.count;XCTAssertEqual(cancelledCalls,1)
    }
    func testStellarRateLimitUsesSavedCatalogAndDoesNotHammerPricing() async throws {
        let transport=RoutingFixture { _ in (Data(),429) }
        let markets=StellarMarkets(transport:transport)
        let saved=StellarCatalog(ids:["native":"stellar"])
        for _ in 0..<3 {
            let catalog=try await markets.catalog(fallback:saved)
            XCTAssertEqual(catalog.ids,saved.ids)
        }
        let prices=try await markets.prices(references:["native"],catalog:saved)
        XCTAssertTrue(prices.isEmpty)
        let calls=await transport.requests.count;XCTAssertEqual(calls,1)
        let updated=await markets.catalogUpdatedAt;XCTAssertNil(updated,"Fallback must not reset successful-cache TTL")
    }
    func testStellarCancellationDoesNotBecomeEmptyCatalogOrStartFallback() async throws {
        let cancelled=StellarMarkets(transport:RoutingFixture { _ in throw CancellationError() })
        do { _=try await cancelled.catalog();XCTFail() } catch is CancellationError { }
        do {
            _=try await cancelled.nativePrice { XCTFail("Cancellation must not start another provider");return nil }
            XCTFail()
        } catch is CancellationError { }
        let unavailable=StellarMarkets(transport:RoutingFixture { _ in (Data(),404) })
        do { _=try await unavailable.nativePrice { throw CancellationError() };XCTFail() } catch is CancellationError { }
    }
    func testStellarConcurrentCatalogLoadsAreCoalescedAndCached() async throws {
        let fixture=try Data(contentsOf:Bundle.module.url(forResource:"catalog",withExtension:"json",subdirectory:"Fixtures/Stellar")!)
        let transport=RoutingFixture { _ in (fixture,200) }
        let shared=StellarMarkets(transport:transport)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for _ in 0..<8 { group.addTask { let value=try await shared.catalog();XCTAssertGreaterThan(value.ids.count,40) } }
            try await group.waitForAll()
        }
        _=try await shared.catalog()
        let calls=await transport.requests.count;XCTAssertEqual(calls,1)
    }
    func testStellarNativePriceUsesAnkrAfterCoinbaseFailure() async throws {
        let transport=RoutingFixture { _ in (Data(),503) }
        let markets=StellarMarkets(transport:transport)
        let value=try await markets.nativePrice { .init(reference:"native",usd:"0.19",source:"ANKR Stellar",fetchedAt:.now) }
        XCTAssertEqual(value.usd,"0.19");XCTAssertEqual(value.source,"ANKR Stellar")
        let requests=await transport.requests;XCTAssertTrue(requests.allSatisfy{$0.url?.host == "api.coinbase.com"})
    }
    func testStellarCatalogOutageKeepsOnlyExactWhitelistedIdentities() throws {
        let issuer="GBDVX4VELCDSQ54KQJYTNHXAHFLBCA77ZY2USQBM4CSHTTV7DME7KALE"
        let other="GBEBCRCJ5VX7GERSGJ5XGJX7K2CHNVQB67K2KGCX7RFGMCBIIZQ5E4GY"
        let genuine=try StellarToken.classic(code:"USDC",issuer:issuer)
        let spoof=try StellarToken.classic(code:"USDC",issuer:other)
        let inventory=StellarInventory(owner:other,ledger:.init(height:1,timestamp:Date().timeIntervalSince1970),exists:true,
            holdings:[.init(reference:genuine.reference,token:genuine,amount:"1",raw:.null),.init(reference:spoof.reference,token:spoof,amount:"1",raw:.null)],
            verified:[genuine.reference],prices:[],observedAt:.now,raw:Data())
        let fallback=StellarCatalog.empty.includingVerified(inventory)
        XCTAssertTrue(fallback.contains(genuine.reference));XCTAssertFalse(fallback.contains(spoof.reference))
        XCTAssertTrue(fallback.ids.isEmpty,"Whitelisting cannot invent a CoinGecko price ID")
    }
    func testStellarNativePriceUsesCoinGeckoAndRejectsStaleOrWrongAsset() async throws {
        let timestamp=Int(Date().timeIntervalSince1970)
        let transport=RoutingFixture { request in
            request.url!.host == "api.coinbase.com" ? (Data(),404):(Data("{\"stellar\":{\"usd\":0.2,\"last_updated_at\":\(timestamp)}}".utf8),200)
        }
        let markets=StellarMarkets(transport:transport)
        let quote=try await markets.nativePrice()
        XCTAssertEqual(quote.source,"CoinGecko");XCTAssertEqual(quote.usd,"0.2")
        for invalid in [StellarPrice(reference:"native",usd:"0.2",source:"fixture",fetchedAt:Date().addingTimeInterval(-7200)),
                        StellarPrice(reference:"wrong",usd:"0.2",source:"fixture",fetchedAt:.now)] {
            do { _=try await markets.nativePrice { invalid };XCTFail("Untrusted quote accepted") }
            catch { XCTAssertEqual(error as? StellarError,.malformed) }
        }
    }
    func testLiveHistoricalReceiptsFromReportedVersions() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CHAIN_FALLBACK_LIVE"] == "1" else { throw XCTSkip("Opt-in read-only public network check") }
        let client=AptosClient(testTransport:AnkrHTTPTransport())
        for version in [7282390031,6136310640,6136315270,6136308008,5956107657] as [Int64] {
            let receipt=try await client.node("transactions/by_version/"+String(version))
            XCTAssertEqual(receipt["version"].text,String(version))
            XCTAssertEqual(receipt["type"].string,"user_transaction")
        }
    }
    func testLiveStellarNativeFallback() async throws {
        guard let key=ProcessInfo.processInfo.environment["OATH_LIVE_STELLAR_KEY"] else { throw XCTSkip("Opt-in public Stellar price check") }
        let client=try StellarClient(apiKey:key)
        // Simulate only Coinbase being unavailable; ANKR is a real read.
        let markets=StellarMarkets(transport:RoutingFixture { _ in (Data(),404) })
        let quote=try await markets.nativePrice { try await client.price(reference:"native") }
        XCTAssertEqual(quote.reference,"native");XCTAssertEqual(quote.source,"ANKR Stellar")
        XCTAssertGreaterThan(Decimal(string:quote.usd)!,0)
        XCTAssertLessThan(Date().timeIntervalSince(quote.fetchedAt),3600)
    }
}
