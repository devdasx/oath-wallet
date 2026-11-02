import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor IndexedQuoteFeed: AnkrTransport {
    enum Mode: Sendable { case healthy, coinbaseUnavailable, independentUnavailable, allUnavailable, wrongIdentity, staleBackup, cancelled }
    let mode: Mode
    let live: Bool
    let requests = PublicMarketRequests(spacing: .zero)
    let transport = AnkrHTTPTransport()
    private(set) var hosts: [String] = []
    init(_ mode: Mode = .healthy, live: Bool = false) { self.mode = mode; self.live = live }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await requests.send(request) { try await self.raw(request) }
        return (response.data, response.status)
    }
    private func raw(_ request: URLRequest) async throws -> PublicMarketRequests.Response {
        let url = try XCTUnwrap(request.url), host = try XCTUnwrap(url.host)
        hosts.append(host)
        if mode == .cancelled { throw CancellationError() }
        if live {
            // Count the actual public providers used by this test; no credentials
            // or wallet data enter these anonymous quote requests.
            let (data, status) = try await transport.send(request)
            return .init(data: data, status: status)
        }
        if mode == .allUnavailable || (host == "api.coinbase.com" && [.coinbaseUnavailable, .independentUnavailable, .staleBackup].contains(mode)) ||
            (host == "coins.llama.fi" && [.independentUnavailable, .staleBackup].contains(mode)) {
            return .init(data: Data(), status: 429)
        }
        let payload: [String: Any]
        if host == "api.coinbase.com" {
            let symbol = url.path.contains("MON-USD") ? "MON" : "ETH"
            payload = ["data": ["base": mode == .wrongIdentity ? "BTC" : symbol, "currency": "USD", "amount": "2.5"]]
        } else if host == "coins.llama.fi" {
            payload = ["coins": [url.lastPathComponent: ["price": 2.5, "confidence": 0.99, "timestamp": Date().timeIntervalSince1970]]]
        } else {
            XCTAssertEqual(host, "api.coingecko.com")
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value ?? ""
            payload = [id: ["usd": 2.5, "last_updated_at": mode == .staleBackup ? 0 : Date().timeIntervalSince1970]]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: payload), status: 200)
    }
}

final class IndexedNativePricePriorityTests: XCTestCase, @unchecked Sendable {
    func testHealthyDirectQuotesNeverRequestCoinGecko() async throws {
        for chain in [IndexedEVMChain.monad, .unichain] {
            let feed = IndexedQuoteFeed(), client = IndexedEVMMarkets(chain: chain, transport: feed)
            let quote = try await client.nativePrice()
            XCTAssertEqual(quote.source, "Coinbase"); XCTAssertEqual(quote.usd, "2.5")
            XCTAssertEqual(quote.chain, chain); XCTAssertEqual(quote.reference, "native")
            let hosts = await feed.hosts; XCTAssertEqual(hosts, ["api.coinbase.com"])
        }
    }
    func testConcurrentAndRepeatedClientsShareDirectQuote() async throws {
        let feed = IndexedQuoteFeed()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let quote = try await IndexedEVMMarkets(chain: .unichain, transport: feed).nativePrice()
                    XCTAssertEqual(quote.source, "Coinbase")
                }
            }
            try await group.waitForAll()
        }
        _ = try await IndexedEVMMarkets(chain: .unichain, transport: feed).nativePrice()
        let hosts = await feed.hosts; XCTAssertEqual(hosts, ["api.coinbase.com"])
    }
    func testIndependentFallbackAndFinalCoinGeckoFallbackRemainAvailable() async throws {
        for chain in [IndexedEVMChain.monad, .unichain] {
            for mode in [IndexedQuoteFeed.Mode.coinbaseUnavailable, .independentUnavailable] {
                let feed = IndexedQuoteFeed(mode)
                let quote = try await IndexedEVMMarkets(chain: chain, transport: feed).nativePrice()
                XCTAssertEqual(quote.source, mode == .coinbaseUnavailable ? "DefiLlama" : "CoinGecko")
                XCTAssertEqual(quote.usd, "2.5")
                let hosts = await feed.hosts
                XCTAssertEqual(hosts, mode == .coinbaseUnavailable ? ["api.coinbase.com", "coins.llama.fi"] : ["api.coinbase.com", "coins.llama.fi", "api.coingecko.com"])
            }
        }
    }
    func testMissingIndependentQuoteStillReachesCoinGecko() async throws {
        for chain in [IndexedEVMChain.monad, .celo, .zerog, .iotex] {
            let feed = SparseNativeQuoteFeed(coinGeckoMissing: false)
            let quote = try await IndexedEVMMarkets(chain: chain, transport: feed).nativePrice()
            XCTAssertEqual(quote.source, "CoinGecko")
            XCTAssertEqual(quote.chain, chain)
            XCTAssertEqual(quote.usd, "1.25")
            let hosts = await feed.hosts
            XCTAssertEqual(hosts, (chain == .monad || chain == .celo ? ["api.coinbase.com"] : []) + ["coins.llama.fi", "api.coingecko.com"])
        }
    }

    func testLiveReportedNetworksReturnIdentifiedFreshNativeQuotes() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_PRICE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only Celo, 0G and IoTeX market checks")
        }
        for chain in [IndexedEVMChain.celo, .zerog, .iotex] {
            let quote = try await IndexedEVMMarkets(chain: chain).nativePrice()
            XCTAssertEqual(quote.chain, chain)
            XCTAssertEqual(quote.reference, "native")
            XCTAssertGreaterThan(try XCTUnwrap(Decimal(string: quote.usd)), 0)
            let age = -quote.fetchedAt.timeIntervalSinceNow
            XCTAssertGreaterThanOrEqual(age, -60)
            XCTAssertLessThan(age, quote.source == "CoinGecko" ? 3600 : 901)
        }
    }

    func testLiveCoinGeckoQuoteRecoversAfterAnEmptyIndex() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_PRICE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public native quote")
        }
        let feed = SparseNativeQuoteFeed(coinGeckoMissing: false, liveBackup: true)
        let quote = try await IndexedEVMMarkets(chain: .monad, transport: feed).nativePrice()
        XCTAssertEqual(quote.chain, .monad)
        XCTAssertEqual(quote.reference, "native")
        XCTAssertEqual(quote.source, "CoinGecko")
        XCTAssertGreaterThan(try XCTUnwrap(Decimal(string: quote.usd)), 0)
        XCTAssertLessThan(abs(quote.fetchedAt.timeIntervalSinceNow), 3600)
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["api.coinbase.com", "coins.llama.fi", "api.coingecko.com"])
    }

    func testEmptyCoinGeckoResultIsUnavailableButWrongCoinAndMalformedRepliesStillFail() async throws {
        let missing = SparseNativeQuoteFeed(coinGeckoMissing: true)
        do {
            _ = try await IndexedEVMMarkets(chain: .monad, transport: missing).nativePrice()
            XCTFail("No provider supplied a quote")
        } catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketQuoteUnavailable) }
        for json in [SolanaJSON.object([:]), .object(["coins": .null]), .object(["coins": .array([])]),
                     .object(["coins": .object(["other": .null])]), .object(["coins": .object([:]), "error": .string("bad")])] {
            XCTAssertThrowsError(try NativePriceFallback.decodeLlama(json, key: "coingecko:monad")) {
                XCTAssertEqual($0 as? AnkrError, .invalidResponse)
            }
        }
        let wrongCoin = SparseNativeQuoteFeed(coinGeckoMissing: false, wrongCoin: true)
        do {
            _ = try await IndexedEVMMarkets(chain: .monad, transport: wrongCoin).nativePrice()
            XCTFail("Wrong quote identity must be rejected")
        } catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
    }

    func testInvalidIdentityAndStaleBackupAreNeverPublished() async throws {
        for mode in [IndexedQuoteFeed.Mode.wrongIdentity, .staleBackup] {
            let feed = IndexedQuoteFeed(mode)
            do { _ = try await IndexedEVMMarkets(chain: .unichain, transport: feed).nativePrice(); XCTFail("Unverified quote returned") }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        }
    }
    func testOutagesDoNotProduceZeroOrRetryRateLimitedProviders() async throws {
        let feed = IndexedQuoteFeed(.allUnavailable)
        do { _ = try await IndexedEVMMarkets(chain: .monad, transport: feed).nativePrice(); XCTFail("Invented quote") }
        catch { XCTAssertEqual(error as? AnkrError, .http(429)) }
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["api.coinbase.com", "coins.llama.fi", "api.coingecko.com"])
    }
    func testCancellationStopsBeforeAnyFallback() async throws {
        let feed = IndexedQuoteFeed(.cancelled)
        do { _ = try await IndexedEVMMarkets(chain: .monad, transport: feed).nativePrice(); XCTFail("Cancelled request succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let hosts = await feed.hosts; XCTAssertEqual(hosts, ["api.coinbase.com"])
    }
    func testLiveDirectQuotesAvoidCoinGeckoAndShareRequests() async throws {
        guard ProcessInfo.processInfo.environment["OATH_NATIVE_PRICE_LIVE"] == "1" else { throw XCTSkip("Opt-in anonymous public quotes") }
        let feed = IndexedQuoteFeed(live: true)
        for chain in [IndexedEVMChain.monad, .unichain] {
            let client = IndexedEVMMarkets(chain: chain, transport: feed)
            async let a = client.nativePrice()
            async let b = client.nativePrice()
            let quotes = try await [a, b]
            for quote in quotes {
                XCTAssertEqual(quote.chain, chain); XCTAssertEqual(quote.reference, "native")
                XCTAssertEqual(quote.source, "Coinbase")
                XCTAssertGreaterThan(try XCTUnwrap(Decimal(string: quote.usd)), 0)
                XCTAssertLessThan(abs(quote.fetchedAt.timeIntervalSinceNow), 60)
            }
            _ = try await client.nativePrice()
        }
        let hosts = await feed.hosts
        XCTAssertEqual(hosts, ["api.coinbase.com", "api.coinbase.com"])
    }
}

private actor SparseNativeQuoteFeed: AnkrTransport {
    let coinGeckoMissing: Bool
    let wrongCoin: Bool
    let liveBackup: Bool
    private(set) var hosts: [String] = []
    init(coinGeckoMissing: Bool, wrongCoin: Bool = false, liveBackup: Bool = false) {
        self.liveBackup = liveBackup
        self.coinGeckoMissing = coinGeckoMissing
        self.wrongCoin = wrongCoin
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let url = try XCTUnwrap(request.url), host = try XCTUnwrap(url.host)
        hosts.append(host)
        switch host {
        case "api.coinbase.com": return (Data(), 429)
        case "coins.llama.fi": return (Data(#"{"coins":{}}"#.utf8), 200)
        case "api.coingecko.com":
            if liveBackup { return try await AnkrHTTPTransport().send(request) }
            if coinGeckoMissing { return (Data("{}".utf8), 200) }
            let id = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "ids" }?.value)
            let payload = [wrongCoin ? "wrong-coin" : id: ["usd": 1.25, "last_updated_at": Date().timeIntervalSince1970]]
            return (try JSONSerialization.data(withJSONObject: payload), 200)
        default: XCTFail("Unexpected provider"); throw AnkrError.invalidResponse
        }
    }
}
