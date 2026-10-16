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
        let envelope = url.path.contains("PROXY") ? #"{"message":"upstream route missing"}"# : #"{"message":"NotFound"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 404,
            httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(envelope.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor final class MarketTransportTests: XCTestCase {
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
            } catch { XCTAssertEqual(error as? MarketDataError, .rateLimited) }
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
