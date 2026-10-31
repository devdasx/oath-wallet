import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private func xrplQuoteFixture(key: String = "coingecko:ripple", price: Double = 1.25,
                              confidence: Double = 0.99, offset: Double = 0, symbol: String = "XRP") -> Data {
    try! JSONSerialization.data(withJSONObject: ["coins": [key: ["price": price, "symbol": symbol, "confidence": confidence,
        "timestamp": Date().timeIntervalSince1970 + offset]]])
}
private let xrplPriceFixture = xrplQuoteFixture()

private actor XrplQuoteReplies: AnkrTransport {
    enum Primary: Sendable {
        case deferred, healthy, unavailable(Int), thrownHTTP(Int), disconnected, cancelled, urlCancelled, wrongAsset, invalidResponse
    }
    let primary: Primary
    let fallback: Data
    let fallbackStatus: Int
    private(set) var calls: [String] = []
    init(_ primary: Primary, fallback: Data = xrplPriceFixture, fallbackStatus: Int = 200) {
        self.primary = primary; self.fallback = fallback; self.fallbackStatus = fallbackStatus
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url!.host!
        calls.append(host)
        if host == "api.coinbase.com" {
            switch primary {
            case .healthy: return (Data(#"{"data":{"base":"XRP","currency":"USD","amount":"3.24"}}"#.utf8), 200)
            case .unavailable(let status): return (Data(), status)
            case .thrownHTTP(let status): throw AnkrError.http(status)
            case .disconnected: throw AnkrError.transport
            case .deferred: throw DiagnosticDeferral.publicMarketCooldown
            case .cancelled: throw CancellationError()
            case .urlCancelled: throw URLError(.cancelled)
            case .wrongAsset: return (Data(#"{"data":{"base":"ETH","currency":"USD","amount":"3000"}}"#.utf8), 200)
            case .invalidResponse: throw AnkrError.invalidResponse
            }
        }
        XCTAssertEqual(host, "coins.llama.fi")
        XCTAssertEqual(request.url!.path, "/prices/current/coingecko:ripple")
        XCTAssertNil(request.url!.query)
        return (fallback, fallbackStatus)
    }
}

final class XrplPriceRecoveryTests: XCTestCase, @unchecked Sendable {
    func testAvailabilityFailuresRecoverFromExistingIdentityMatchedProvider() async throws {
        for primary in [XrplQuoteReplies.Primary.disconnected, .deferred, .unavailable(429), .unavailable(503), .thrownHTTP(429)] {
            let transport = XrplQuoteReplies(primary)
            let quote = try await XrplMarkets(transport: transport).nativePrice()
            XCTAssertEqual(quote.reference, "native")
            XCTAssertEqual(quote.usd, "1.25")
            XCTAssertEqual(quote.source, "DefiLlama")
            let calls = await transport.calls
            XCTAssertEqual(calls.filter { $0 == "coins.llama.fi" }.count, 1)
            XCTAssertLessThanOrEqual(calls.count, 3)
        }
    }
    func testHealthyPrimaryDoesNotFetchFallback() async throws {
        let transport = XrplQuoteReplies(.healthy)
        let quote = try await XrplMarkets(transport: transport).nativePrice()
        XCTAssertEqual(quote.usd, "3.24"); XCTAssertEqual(quote.source, "Coinbase")
        let calls = await transport.calls
        XCTAssertEqual(calls, ["api.coinbase.com"])
    }
    func testCancellationInvalidIdentityAndAuthorizationDoNotBecomeFallbackSuccess() async {
        for primary in [XrplQuoteReplies.Primary.cancelled, .urlCancelled, .wrongAsset, .unavailable(401), .thrownHTTP(401), .invalidResponse] {
            let transport = XrplQuoteReplies(primary)
            do { _ = try await XrplMarkets(transport: transport).nativePrice(); XCTFail("Expected failure") }
            catch {
                switch primary {
                case .cancelled, .urlCancelled: XCTAssertTrue(error is CancellationError)
                case .wrongAsset, .invalidResponse: XCTAssertEqual(error as? XrplError, .malformed)
                default: XCTAssertEqual(error as? XrplError, .http(401))
                }
            }
            let calls = await transport.calls
            XCTAssertEqual(calls, ["api.coinbase.com"])
        }
    }
    func testExpiredFallbackIsUnavailableAndNeverReturnedAsFresh() async {
        let transport = XrplQuoteReplies(.disconnected, fallback: xrplQuoteFixture(offset: -901))
        do { _ = try await XrplMarkets(transport: transport).nativePrice(); XCTFail("Expired fallback accepted") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketQuoteUnavailable) }
    }
    func testInvalidFallbackNeverInventsNativePrice() async {
        for payload in [Data(#"{"coins":{}}"#.utf8), xrplQuoteFixture(key: "coingecko:ethereum"),
                        xrplQuoteFixture(symbol: "ETH"), xrplQuoteFixture(price: 0), xrplQuoteFixture(price: -1),
                        xrplQuoteFixture(confidence: 0.89), xrplQuoteFixture(confidence: 1.01),
                        xrplQuoteFixture(offset: 61)] {
            let transport = XrplQuoteReplies(.disconnected, fallback: payload)
            do { _ = try await XrplMarkets(transport: transport).nativePrice(); XCTFail("Invalid fallback accepted") }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        }
        let transport = XrplQuoteReplies(.disconnected, fallbackStatus: 429)
        do { _ = try await XrplMarkets(transport: transport).nativePrice(); XCTFail("Unavailable fallback accepted") }
        catch { XCTAssertEqual(error as? XrplError, .http(429)) }
    }
}

private actor XrplPriceReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class XrplPriceRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // The shared outbox configures once; run this class in its own process.
    func testAvailabilityAndCancellationStayQuietButInvalidPricesAreReported() async throws {
        let reports = XrplPriceReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let expectedID = UUID()
        try await OathDiagnostics.$operationID.withValue(expectedID) {
            try await OathDiagnostics.$chain.withValue("ethereum") {
                let quote = try await XrplMarkets(transport: XrplQuoteReplies(.disconnected)).nativePrice()
                XCTAssertEqual(quote.source, "DefiLlama")
                XCTAssertEqual(OathDiagnostics.chain, "ethereum")
            }
        }
        do { _ = try await XrplMarkets(transport: XrplQuoteReplies(.urlCancelled)).nativePrice(); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        // Availability and cancellation are intentionally excluded. Exercise
        // a real validation rejection as a positive control for delivery/privacy.
        let invalid = await OathDiagnostics.$operationID.withValue(expectedID) {
            await OathDiagnostics.withChain("xrpl") {
                await OathDiagnostics.attempt("price_validation_fixture") {
                    try await XrplMarkets(transport: XrplQuoteReplies(.wrongAsset)).nativePrice()
                }
            }
        }
        XCTAssertNil(invalid, "A wrong native-asset identity must never return a price")
        for _ in 0..<200 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        await OathDiagnostics.flush()
        let events = await reports.events
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "xrpl" && $0.operationID == expectedID && $0.privacyFiltered })
        XCTAssertEqual(events.first?.operation, "price_validation_fixture")
        XCTAssertEqual(events.first?.error.message, "malformed")
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(payload.contains("https://")); XCTAssertFalse(payload.contains("coingecko:ripple"))
        XCTAssertNil(OathDiagnostics.chain); XCTAssertNil(OathDiagnostics.operationID)
    }
}

private struct XrplOutageWithLiveFallback: AnkrTransport {
    let live = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" { throw AnkrError.transport }
        return try await live.send(request)
    }
}

final class XrplPriceLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyLiveFallbackAgainstIndependentPrimary() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_XRP_QUOTES"] == "1" else {
            throw XCTSkip("Opt-in public XRP quote read; no wallet or transaction")
        }
        let primary = try await XrplMarkets().nativePrice()
        XCTAssertEqual(primary.source, "Coinbase", "Comparison must use independent providers")
        let recovered = try await XrplMarkets(transport: XrplOutageWithLiveFallback()).nativePrice()
        XCTAssertEqual(recovered.source, "DefiLlama"); XCTAssertEqual(recovered.reference, "native")
        let a = try XCTUnwrap(Double(primary.usd)), b = try XCTUnwrap(Double(recovered.usd))
        XCTAssertGreaterThan(a, 0); XCTAssertGreaterThan(b, 0)
        XCTAssertLessThan(abs(a-b)/a, 0.10)
        print("XRP_LIVE_PRICE verified primary=Coinbase fallback=DefiLlama tolerance=10percent broadcast=false")
    }
}

private final class XrplQuoteProtocol: URLProtocol, @unchecked Sendable {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var value: [String: Int] = [:]
    }
    private static let counts = Counts()
    static var requestCounts: [String: Int] { counts.lock.withLock { counts.value } }
    override class func canInit(with request: URLRequest) -> Bool {
        ["api.coinbase.com", "coins.llama.fi"].contains(request.url?.host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url!.host!
        Self.counts.lock.withLock { Self.counts.value[host, default: 0] += 1 }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) {
            let primary = host == "api.coinbase.com"
            let response = HTTPURLResponse(url: self.request.url!, statusCode: primary ? 429 : 200,
                                           httpVersion: nil, headerFields: primary ? ["Retry-After": "60"] : nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: primary ? Data() : xrplPriceFixture)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

final class XrplPriceSharedTransportTests: XCTestCase, @unchecked Sendable {
    // Isolated process: use the real shared cache, HTTP client and URLSession.
    func testConcurrentAndRepeatedNativePricesShareFallbackAndHonorPrimaryCooldown() async throws {
        func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [XrplQuoteProtocol.self]
            return URLSession(configuration: configuration)
        }
        let first = session(), second = session()
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        let one = XrplMarkets(transport: AnkrHTTPTransport(session: first))
        let two = XrplMarkets(transport: AnkrHTTPTransport(session: second))
        async let a = one.nativePrice()
        async let b = two.nativePrice()
        let (left, right) = try await (a, b)
        XCTAssertEqual(left.usd, "1.25"); XCTAssertEqual(right.usd, "1.25")
        _ = try await two.nativePrice()
        XCTAssertEqual(XrplQuoteProtocol.requestCounts, ["api.coinbase.com": 1, "coins.llama.fi": 1])
    }
}
