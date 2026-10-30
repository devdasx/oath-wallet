import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private let nearPriceFixture = Data(#"{"wrap.near":{"decimal":24,"price":"3.25"}}"#.utf8)

private actor NearQuoteReplies: AnkrTransport {
    enum Primary: Sendable { case deferred, healthy, unavailable(Int), disconnected, cancelled, urlCancelled, wrongAsset }
    let primary: Primary
    let fallback: Data
    let fallbackStatus: Int
    private(set) var calls: [String] = []
    init(_ primary: Primary, fallback: Data = nearPriceFixture, fallbackStatus: Int = 200) {
        self.primary = primary; self.fallback = fallback; self.fallbackStatus = fallbackStatus
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url!.host!
        calls.append(host)
        if host == "api.coinbase.com" {
            switch primary {
            case .healthy: return (Data(#"{"data":{"base":"NEAR","currency":"USD","amount":"3.24"}}"#.utf8), 200)
            case .unavailable(let status): return (Data(), status)
            case .disconnected: throw AnkrError.transport
            case .deferred: throw DiagnosticDeferral.publicMarketCooldown
            case .cancelled: throw CancellationError()
            case .urlCancelled: throw URLError(.cancelled)
            case .wrongAsset: return (Data(#"{"data":{"base":"ETH","currency":"USD","amount":"3000"}}"#.utf8), 200)
            }
        }
        XCTAssertEqual(host, "prices.intear.tech")
        XCTAssertEqual(request.url!.path, "/list-token-price")
        XCTAssertNil(request.url!.query)
        return (fallback, fallbackStatus)
    }
}

final class NearPriceRecoveryTests: XCTestCase, @unchecked Sendable {
    func testAvailabilityFailuresRecoverFromExistingNEARProvider() async throws {
        for primary in [NearQuoteReplies.Primary.disconnected, .deferred, .unavailable(429), .unavailable(503)] {
            let transport = NearQuoteReplies(primary)
            let quote = try await NearMarkets(transport: transport).nativePrice()
            XCTAssertEqual(quote.reference, "native")
            XCTAssertEqual(quote.usd, "3.25")
            XCTAssertEqual(quote.source, "Intear")
            let calls = await transport.calls
            XCTAssertEqual(calls.filter { $0 == "prices.intear.tech" }.count, 1)
            XCTAssertLessThanOrEqual(calls.count, 3)
        }
    }
    func testHealthyPrimaryDoesNotFetchFallback() async throws {
        let transport = NearQuoteReplies(.healthy)
        let quote = try await NearMarkets(transport: transport).nativePrice()
        XCTAssertEqual(quote.usd, "3.24")
        XCTAssertEqual(quote.source, "Coinbase")
        let calls = await transport.calls
        XCTAssertEqual(calls, ["api.coinbase.com"])
    }
    func testCancellationAndWrongIdentityDoNotBecomeFallbackSuccess() async {
        for primary in [NearQuoteReplies.Primary.cancelled, .urlCancelled, .wrongAsset, .unavailable(401)] {
            let transport = NearQuoteReplies(primary)
            do { _ = try await NearMarkets(transport: transport).nativePrice(); XCTFail("Expected failure") }
            catch {
                switch primary {
                case .cancelled, .urlCancelled: XCTAssertTrue(error is CancellationError)
                case .wrongAsset: XCTAssertEqual(error as? NearError, .malformed)
                default: XCTAssertEqual(error as? NearError, .http(401))
                }
            }
            let calls = await transport.calls
            XCTAssertEqual(calls, ["api.coinbase.com"])
        }
    }
    func testInvalidFallbackNeverInventsNativePrice() async {
        for payload in [#"{}"#, #"{"wrap.near":{"decimal":6,"price":"3.25"}}"#,
                        #"{"wrap.near":{"decimal":24,"price":"0"}}"#,
                        #"{"wrap.near":{"decimal":24,"price":"-5"}}"#] {
            let transport = NearQuoteReplies(.disconnected, fallback: Data(payload.utf8))
            do { _ = try await NearMarkets(transport: transport).nativePrice(); XCTFail("Invalid fallback accepted") }
            catch { XCTAssertEqual(error as? NearError, .malformed) }
        }
        let transport = NearQuoteReplies(.disconnected, fallbackStatus: 429)
        do { _ = try await NearMarkets(transport: transport).nativePrice(); XCTFail("Unavailable fallback accepted") }
        catch { XCTAssertEqual(error as? NearError, .http(429)) }
    }
    func testEmptyTokenCollectionDoesNotRequestWholeMarket() async throws {
        let transport = NearQuoteReplies(.healthy)
        let quotes = try await NearMarkets(transport: transport).ecosystemPrices(tokens: [])
        XCTAssertTrue(quotes.isEmpty)
        let calls = await transport.calls
        XCTAssertTrue(calls.isEmpty)
    }
    func testOnlyExactAnonymousBulkQuoteRouteCanShareCache() {
        let url = URL(string: "https://prices.intear.tech/list-token-price")!
        XCTAssertTrue(PublicMarketRequests.accepts(URLRequest(url: url)))
        for text in ["https://prices.intear.tech/accounts", "https://prices.intear.tech/list-token-price?account_id=fixture",
                     "https://prices.intear.tech:443/list-token-price", "https://prices.intear.tech/list-token-price#fragment"] {
            XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: text)!)))
        }
        var authenticated = URLRequest(url: url)
        authenticated.setValue("fixture-only", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
        var mutation = URLRequest(url: url); mutation.httpMethod = "POST"
        XCTAssertFalse(PublicMarketRequests.accepts(mutation))
    }
}

private actor NearPriceReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class NearPriceRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // The shared outbox configures once; run this class in its own process.
    func testRecoveredOutageStaysCorrelatedAndCancellationStaysQuiet() async throws {
        let reports = NearPriceReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let expectedID = UUID()
        try await OathDiagnostics.$operationID.withValue(expectedID) {
            try await OathDiagnostics.$chain.withValue("ethereum") {
                let quote = try await NearMarkets(transport: NearQuoteReplies(.disconnected)).nativePrice()
                XCTAssertEqual(quote.source, "Intear")
                XCTAssertEqual(OathDiagnostics.chain, "ethereum")
            }
        }
        do { _ = try await NearMarkets(transport: NearQuoteReplies(.urlCancelled)).nativePrice(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "near" && $0.operationID == expectedID && $0.privacyFiltered })
        XCTAssertTrue(events.contains { $0.context["host"] == "api.coinbase.com" && $0.error.domain == "OathAnkr.AnkrError" })
        XCTAssertTrue(events.contains { $0.operation == "near_native_fallback" && $0.context["stage"] == "quote" })
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(payload.contains("https://")); XCTAssertFalse(payload.contains("wrap.near"))
        XCTAssertNil(OathDiagnostics.chain); XCTAssertNil(OathDiagnostics.operationID)
    }
}

private struct NearOutageWithLiveFallback: AnkrTransport {
    let live = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" { throw AnkrError.transport }
        return try await live.send(request)
    }
}

final class NearPriceLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyLiveFallbackAgainstIndependentPrimary() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_QUOTES"] == "1" else {
            throw XCTSkip("Opt-in public NEAR quote read; no wallet or transaction")
        }
        let primary = try await NearMarkets().nativePrice()
        XCTAssertEqual(primary.source, "Coinbase", "Comparison must use independent providers")
        let recovered = try await NearMarkets(transport: NearOutageWithLiveFallback()).nativePrice()
        XCTAssertEqual(recovered.source, "Intear"); XCTAssertEqual(recovered.reference, "native")
        let a = try XCTUnwrap(Double(primary.usd)), b = try XCTUnwrap(Double(recovered.usd))
        XCTAssertGreaterThan(a, 0); XCTAssertGreaterThan(b, 0)
        XCTAssertLessThan(abs(a-b)/a, 0.15)
        print("NEAR_LIVE_PRICE verified primary=Coinbase fallback=Intear tolerance=15percent broadcast=false")
    }
}

private final class NearBulkQuoteProtocol: URLProtocol, @unchecked Sendable {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
    }
    private static let counts = Counts()
    static var count: Int { counts.lock.withLock { counts.value } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "prices.intear.tech" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counts.lock.withLock { Self.counts.value += 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: nearPriceFixture)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

final class NearPriceSharedTransportTests: XCTestCase, @unchecked Sendable {
    // Separate process keeps the production shared cache isolated from other fixtures.
    func testSeparateWalletMarketClientsShareOneBulkReadAndCache() async throws {
        func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NearBulkQuoteProtocol.self]
            return URLSession(configuration: configuration)
        }
        let first = session(), second = session()
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        let one = NearMarkets(transport: AnkrHTTPTransport(session: first))
        let two = NearMarkets(transport: AnkrHTTPTransport(session: second))
        async let a = one.ecosystemPrices(tokens: [.native])
        async let b = two.ecosystemPrices(tokens: [.native])
        let (left, right) = try await (a, b)
        XCTAssertEqual(left.first?.usd, "3.25"); XCTAssertEqual(right.first?.usd, "3.25")
        _ = try await two.ecosystemPrices(tokens: [.native])
        XCTAssertEqual(NearBulkQuoteProtocol.count, 1, "Public prices should not be fetched once per wallet")
    }
}
