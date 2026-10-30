import Foundation
import XCTest
@testable import OathAnkr

private actor NativePriceTransport: AnkrTransport {
    let primaryStatus: Int
    let fallbackStatus: Int
    let body: String?
    let cancel: Bool
    let freshPrimary: Bool
    private(set) var hosts: [String] = []
    init(primaryStatus: Int = 429, fallbackStatus: Int = 200, body: String? = nil, cancel: Bool = false, freshPrimary: Bool = false) {
        self.primaryStatus=primaryStatus;self.fallbackStatus=fallbackStatus;self.body=body;self.cancel=cancel;self.freshPrimary=freshPrimary
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url=try XCTUnwrap(request.url);hosts.append(url.host ?? "")
        if cancel { throw CancellationError() }
        if url.host == "api.coingecko.com" {
            let id=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="ids"})?.value ?? ""
            let timestamp=freshPrimary ? Date().timeIntervalSince1970 : 0
            let data=try JSONSerialization.data(withJSONObject:[id:["usd":2,"last_updated_at":timestamp]])
            return (data,primaryStatus)
        }
        if url.host == "coins.llama.fi" { return (Data(), fallbackStatus) }
        XCTAssertEqual(url.host,"api.coinbase.com")
        let code=url.path.components(separatedBy:"/").dropLast().last?.components(separatedBy:"-").first ?? ""
        let data=try body.map { Data($0.utf8) } ?? JSONSerialization.data(withJSONObject:["data":["base":code,"currency":"USD","amount":"1.25"]])
        return (data,fallbackStatus)
    }
}

private actor NativePriceLiveTransport: AnkrTransport {
    private let base=AnkrHTTPTransport()
    private(set) var fallbackRequests=0
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        guard request.httpBody==nil,request.httpMethod==nil || request.httpMethod=="GET" else { throw AnkrError.invalidResponse }
        if request.url?.host=="api.coingecko.com" { return (Data(),429) }
        guard request.url?.host=="api.coinbase.com" else { throw AnkrError.invalidResponse }
        fallbackRequests += 1
        return try await base.send(request)
    }
}

final class NativePriceFallbackTests: XCTestCase, @unchecked Sendable {
    private func price(_ chain:String,transport:any AnkrTransport) async throws -> (String,String) {
        if chain=="hyperevm" {
            let value=try await HyperEVMMarkets(transport:transport).nativePrice()
            XCTAssertEqual(value.reference,"native")
            return (value.usd,value.source)
        }
        let network=try XCTUnwrap(IndexedEVMChain(rawValue:chain))
        let value=try await IndexedEVMMarkets(chain:network,transport:transport).nativePrice()
        XCTAssertEqual(value.chain,network);XCTAssertEqual(value.reference,"native")
        return (value.usd,value.source)
    }
    func testRateLimitedNativePricesRecoverForEachExactNetwork() async throws {
        for chain in ["unichain","monad","hyperevm"] {
            let transport=NativePriceTransport()
            let value=try await price(chain,transport:transport)
            XCTAssertEqual(value.0,"1.25");XCTAssertEqual(value.1,"Coinbase")
            let hosts=await transport.hosts
            XCTAssertEqual(hosts, chain == "hyperevm" ? ["api.coingecko.com","api.coinbase.com"] : ["api.coinbase.com"])
        }
    }
    func testStalePrimaryIsNotPublishedAsFresh() async throws {
        let transport=NativePriceTransport(primaryStatus:200)
        let value=try await price("hyperevm",transport:transport)
        XCTAssertEqual(value.0,"1.25");XCTAssertEqual(value.1,"Coinbase")
    }
    func testHealthyPrimaryDoesNotSpendFallbackQuota() async throws {
        let transport=NativePriceTransport(primaryStatus:200,freshPrimary:true)
        let value=try await price("hyperevm",transport:transport)
        XCTAssertEqual(value.0,"2");XCTAssertEqual(value.1,"CoinGecko")
        let hosts=await transport.hosts;XCTAssertEqual(hosts,["api.coingecko.com"])
    }
    func testWrongIdentityCurrencyAndInvalidValuesNeverBecomePrices() async throws {
        for body in [
            #"{"data":{"base":"BTC","currency":"USD","amount":"1"}}"#,
            #"{"data":{"base":"ETH","currency":"EUR","amount":"1"}}"#,
            #"{"data":{"base":"ETH","currency":"USD","amount":"0"}}"#,
            #"{"data":{"base":"ETH","currency":"USD","amount":"-1"}}"#,
            #"{"data":{"base":"ETH","currency":"USD","amount":"1garbage"}}"#,
            #"{"data":{"base":"ETH","currency":"USD","amount":"NaN"}}"#,
            #"{"data":{"currency":"USD","amount":"1"}}"#
        ] {
            let transport=NativePriceTransport(body:body)
            do { _=try await price("unichain",transport:transport);XCTFail("Invalid quote accepted") }
            catch { XCTAssertEqual(error as? AnkrError,.invalidResponse) }
        }
    }
    func testBothProvidersUnavailableCannotProduceZero() async throws {
        let transport=NativePriceTransport(fallbackStatus:429)
        do { _=try await price("hyperevm",transport:transport);XCTFail("Invented price") }
        catch { XCTAssertEqual(error as? AnkrError,.http(429)) }
        let hosts=await transport.hosts;XCTAssertEqual(hosts,["api.coingecko.com","api.coinbase.com","coins.llama.fi"])
    }
    func testCancellationDoesNotStartAnotherProvider() async throws {
        let transport=NativePriceTransport(cancel:true)
        do { _=try await price("monad",transport:transport);XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let hosts=await transport.hosts;XCTAssertEqual(hosts,["api.coinbase.com"])
    }
    func testLiveFallbackQuotesForAllThreeNativeAssets() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_PRICE_LIVE"]=="1" else { throw XCTSkip("Opt-in public price reads") }
        let transport=NativePriceLiveTransport()
        for chain in ["unichain","monad","hyperevm"] {
            let value=try await price(chain,transport:transport)
            XCTAssertGreaterThan(try XCTUnwrap(Decimal(string:value.0)),0)
            XCTAssertEqual(value.1,"Coinbase")
        }
        let count=await transport.fallbackRequests;XCTAssertEqual(count,3)
    }

    func testLiveHyperEVMPriceThroughDefaultTransport() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_PRICE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public HYPE price read through the app transport")
        }
        let value = try await HyperEVMMarkets().nativePrice()
        XCTAssertEqual(value.reference, "native")
        XCTAssertGreaterThan(try XCTUnwrap(Decimal(string: value.usd)), 0)
        XCTAssertTrue(["CoinGecko", "Coinbase", "DefiLlama"].contains(value.source))
        XCTAssertLessThan(Date().timeIntervalSince(value.fetchedAt), 3600)
        XCTAssertLessThanOrEqual(value.fetchedAt.timeIntervalSinceNow, 60)
        print("LIVE_HYPE_PRICE source=\(value.source) positive=true fresh=true")
    }
}
