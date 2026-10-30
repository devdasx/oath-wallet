import OathDiagnostics
import XCTest
@testable import OathMarketData

private final class RequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [String: Int] = [:]
    func record(_ host: String) { lock.withLock { hosts[host, default: 0] += 1 } }
    func count(_ host: String) -> Int { lock.withLock { hosts[host, default: 0] } }
    func reset() { lock.withLock { hosts = [:] } }
}

/// Exercises the real URLSession transport without any public network requests.
private final class RateLimitProtocol: URLProtocol, @unchecked Sendable {
    static let counts = RequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.counts.record(url.host!)
        let throttled = url.host == "api.coingecko.com"
        let response = HTTPURLResponse(url: url, statusCode: throttled ? 429 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private final class MissingMarketProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let envelope: String
        if url.host == "api.coinbase.com" {
            envelope = #"{"error":"rpc error: code = NotFound desc = rate found but was stale","code":5,"message":"rpc error: code = NotFound desc = rate found but was stale"}"#
        } else {
            envelope = url.path.contains("PROXY") ? #"{"message":"upstream route missing"}"# : #"{"message":"NotFound"}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404,
            httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(envelope.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor final class MarketTransportTests: XCTestCase {
    func testRealTransportPreservesStaleQuoteAsFallbackOutcome() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MissingMarketProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMarketTransport(session: session)
        do {
            _ = try await transport.data(from: URL(string: "https://api.coinbase.com/v2/prices/DOGE-USD/spot")!)
            XCTFail("Stale provider response must not become a price")
        } catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketQuoteUnavailable) }
    }
    func testKrakenAdmissionAllowsOnlyTheVerifiedPublicNativeMarkets() async throws {
        RateLimitProtocol.counts.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateLimitProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMarketTransport(session: session)
        for market in KrakenNativeChart.Market.allCases {
            let url = KrakenNativeChart.url(for: market)
            _ = try await transport.data(from: url)
            _ = try await transport.data(from: url)
            for value in ["https://api.kraken.com/0/private/Balance", url.absoluteString + "&key=fixture",
                          url.absoluteString + "#fragment", url.absoluteString.replacingOccurrences(of: market.pair, with: "ETHUSD"),
                          url.absoluteString.replacingOccurrences(of: "interval=60", with: "interval=1")] {
                do { _ = try await transport.data(from: URL(string: value)!); XCTFail("Expanded Kraken admission") }
                catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
            }
        }
        XCTAssertEqual(RateLimitProtocol.counts.count("api.kraken.com"), 4)
    }
    func testPaprikaAdmissionIsLimitedToVerifiedPublicNativeEndpoints() async throws {
        RateLimitProtocol.counts.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateLimitProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMarketTransport(session: session)
        for identity in [NativeInformation.rune, NativeInformation.doge, NativeInformation.bitcoin, NativeInformation.bitcoinCash,
                         NativeInformation.sui, NativeInformation.aptos, NativeInformation.okb] {
            for url in [identity.coinURL, identity.tickerURL] {
                _ = try await transport.data(from: url)
                _ = try await transport.data(from: url)
            }
        }
        for url in [
            "https://api.coinpaprika.com/v1/coins/ltc-litecoin", "https://api.coinpaprika.com/v1/coins/rune-thorchain?key=fixture",
            "https://api.coinpaprika.com:444/v1/coins/rune-thorchain", "http://api.coinpaprika.com/v1/coins/rune-thorchain",
            "https://user:pass@api.coinpaprika.com/v1/coins/rune-thorchain", "https://api.coinpaprika.com/v1/coins/rune-thorchain#extra"
        ] {
            do { _ = try await transport.data(from: URL(string: url)!); XCTFail("Expanded admission") }
            catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        }
        XCTAssertEqual(RateLimitProtocol.counts.count("api.coinpaprika.com"), 14)
    }

    func testMidgardAdmissionAllowsOnlyThePublicRuneHistoryRoute() async throws {
        RateLimitProtocol.counts.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateLimitProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMarketTransport(session: session)
        let approved = try ThorchainChart.url(at: Date())
        _ = try await transport.data(from: approved)
        XCTAssertEqual(RateLimitProtocol.counts.count("gateway.liquify.com"), 1)
        for url in [
            approved.absoluteString.replacingOccurrences(of: "/history/rune", with: "/actions"),
            approved.absoluteString.replacingOccurrences(of: "https://", with: "http://"),
            approved.absoluteString.replacingOccurrences(of: "gateway.liquify.com", with: "gateway.liquify.com:444"),
            approved.absoluteString.replacingOccurrences(of: "https://", with: "https://test@test:"),
            approved.absoluteString + "&token=fixture",
            approved.absoluteString + "&count=25",
            approved.absoluteString.replacingOccurrences(of: "count=25", with: "count=400")
        ] {
            guard let url = URL(string: url) else { continue }
            do { _ = try await transport.data(from: url); XCTFail("Expanded endpoint admission") }
            catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        }
        XCTAssertEqual(RateLimitProtocol.counts.count("gateway.liquify.com"), 1)
    }

    func testOnlyExactListing404BecomesAbsentMarketData() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MissingMarketProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMarketTransport(session: session)
        for (path, expected) in [
            ("/products/ABSENT-USD/candles", MarketDataError.notListed),
            ("/products/PROXY-USD/candles", .unavailable),
            ("/currencies", .unavailable)
        ] {
            do { _ = try await transport.data(from: URL(string: "https://api.exchange.coinbase.com" + path)!); XCTFail("Expected absence/failure") }
            catch { XCTAssertEqual(error as? MarketDataError, expected) }
        }
    }

    func testProviderRateLimitBlocksOtherAssetsButNotOtherProviders() async throws {
        RateLimitProtocol.counts.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RateLimitProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let transport = URLSessionMarketTransport(session: session)
        for coin in ["ethereum", "bitcoin", "solana"] {
            do {
                _ = try await transport.data(from: URL(string: "https://api.coingecko.com/api/v3/coins/" + coin)!)
                XCTFail("Expected provider cooldown")
            } catch {
                if coin == "ethereum" { XCTAssertEqual(error as? MarketDataError, .rateLimited) }
                else { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
            }
        }
        XCTAssertEqual(RateLimitProtocol.counts.count("api.coingecko.com"), 1)
        _ = try await transport.data(from: URL(string: "https://api.coinbase.com/v2/prices/ETH-USD/spot")!)
        XCTAssertEqual(RateLimitProtocol.counts.count("api.coinbase.com"), 1)
        for endpoint in ["http://api.coinbase.com/test", "https://untrusted.example/test"] {
            do { _ = try await transport.data(from: URL(string: endpoint)!); XCTFail("Unapproved endpoint") }
            catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        }
        XCTAssertEqual(RateLimitProtocol.counts.count("untrusted.example"), 0)
    }
}
