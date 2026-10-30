import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private let suiPriceFixture = Data(#"[{"chainId":"sui","baseToken":{"address":"0x2::sui::SUI"},"priceUsd":"3.25","liquidity":{"usd":2000000}}]"#.utf8)

private actor SuiQuoteReplies: AnkrTransport {
    enum Primary: Sendable {
        case deferred, healthy, unavailable(Int), thrownHTTP(Int), disconnected, cancelled, urlCancelled, wrongAsset, invalidResponse
    }
    let primary: Primary
    let fallback: Data
    let fallbackStatus: Int
    private(set) var calls: [String] = []
    init(_ primary: Primary, fallback: Data = suiPriceFixture, fallbackStatus: Int = 200) {
        self.primary = primary; self.fallback = fallback; self.fallbackStatus = fallbackStatus
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url!.host!
        calls.append(host)
        if host == "api.coinbase.com" {
            switch primary {
            case .healthy: return (Data(#"{"data":{"base":"SUI","currency":"USD","amount":"3.24"}}"#.utf8), 200)
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
        XCTAssertEqual(host, "api.dexscreener.com")
        XCTAssertEqual(request.url!.path, "/tokens/v1/sui/0x2::sui::SUI")
        XCTAssertNil(request.url!.query)
        return (fallback, fallbackStatus)
    }
}

final class SuiPriceRecoveryTests: XCTestCase, @unchecked Sendable {
    func testAvailabilityFailuresRecoverFromExistingContractMatchedProvider() async throws {
        for primary in [SuiQuoteReplies.Primary.disconnected, .deferred, .unavailable(429), .unavailable(503), .thrownHTTP(429)] {
            let transport = SuiQuoteReplies(primary)
            let quote = try await SuiMarkets(transport: transport).nativePrice()
            XCTAssertEqual(quote.reference, "native")
            XCTAssertEqual(quote.usd, "3.25")
            XCTAssertEqual(quote.source, "DEX Screener")
            let calls = await transport.calls
            XCTAssertEqual(calls.filter { $0 == "api.dexscreener.com" }.count, 1)
            XCTAssertLessThanOrEqual(calls.count, 3)
        }
    }
    func testHealthyPrimaryDoesNotFetchFallback() async throws {
        let transport = SuiQuoteReplies(.healthy)
        let quote = try await SuiMarkets(transport: transport).nativePrice()
        XCTAssertEqual(quote.usd, "3.24"); XCTAssertEqual(quote.source, "Coinbase")
        let calls = await transport.calls
        XCTAssertEqual(calls, ["api.coinbase.com"])
    }
    func testCancellationInvalidIdentityAndAuthorizationDoNotBecomeFallbackSuccess() async {
        for primary in [SuiQuoteReplies.Primary.cancelled, .urlCancelled, .wrongAsset, .unavailable(401), .thrownHTTP(401), .invalidResponse] {
            let transport = SuiQuoteReplies(primary)
            do { _ = try await SuiMarkets(transport: transport).nativePrice(); XCTFail("Expected failure") }
            catch {
                switch primary {
                case .cancelled, .urlCancelled: XCTAssertTrue(error is CancellationError)
                case .wrongAsset, .invalidResponse: XCTAssertEqual(error as? SuiError, .malformed)
                default: XCTAssertEqual(error as? SuiError, .http(401))
                }
            }
            let calls = await transport.calls
            XCTAssertEqual(calls, ["api.coinbase.com"])
        }
    }
    func testInvalidFallbackNeverInventsNativePrice() async {
        for payload in [#"[]"#,
                        #"[{"chainId":"ethereum","baseToken":{"address":"0x2::sui::SUI"},"priceUsd":"3.25","liquidity":{"usd":2000000}}]"#,
                        #"[{"chainId":"sui","baseToken":{"address":"0x3::sui::SUI"},"priceUsd":"3.25","liquidity":{"usd":2000000}}]"#,
                        #"[{"chainId":"sui","baseToken":{"address":"0x2::sui::SUI"},"priceUsd":"3.25","liquidity":{"usd":999}}]"#,
                        #"[{"chainId":"sui","baseToken":{"address":"0x2::sui::SUI"},"priceUsd":"0","liquidity":{"usd":2000000}}]"#] {
            let transport = SuiQuoteReplies(.disconnected, fallback: Data(payload.utf8))
            do { _ = try await SuiMarkets(transport: transport).nativePrice(); XCTFail("Invalid fallback accepted") }
            catch { XCTAssertEqual(error as? SuiError, .malformed) }
        }
        let transport = SuiQuoteReplies(.disconnected, fallbackStatus: 429)
        do { _ = try await SuiMarkets(transport: transport).nativePrice(); XCTFail("Unavailable fallback accepted") }
        catch { XCTAssertEqual(error as? SuiError, .http(429)) }
    }
}

private actor SuiPriceReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class SuiPriceRecoveryDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // The shared outbox configures once; run this class in its own process.
    func testRecoveredOutageStaysCorrelatedAndCancellationStaysQuiet() async throws {
        let reports = SuiPriceReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let expectedID = UUID()
        try await OathDiagnostics.$operationID.withValue(expectedID) {
            try await OathDiagnostics.$chain.withValue("ethereum") {
                let quote = try await SuiMarkets(transport: SuiQuoteReplies(.disconnected)).nativePrice()
                XCTAssertEqual(quote.source, "DEX Screener")
                XCTAssertEqual(OathDiagnostics.chain, "ethereum")
            }
        }
        do { _ = try await SuiMarkets(transport: SuiQuoteReplies(.urlCancelled)).nativePrice(); XCTFail() }
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
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "sui" && $0.operationID == expectedID && $0.privacyFiltered })
        XCTAssertTrue(events.contains { $0.context["host"] == "api.coinbase.com" && $0.error.domain == "OathAnkr.AnkrError" })
        XCTAssertTrue(events.contains { $0.operation == "sui_native_fallback" && $0.context["stage"] == "quote" })
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(payload.contains("https://")); XCTAssertFalse(payload.contains("0x2::sui::SUI"))
        XCTAssertNil(OathDiagnostics.chain); XCTAssertNil(OathDiagnostics.operationID)
    }
}

private struct SuiOutageWithLiveFallback: AnkrTransport {
    let live = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "api.coinbase.com" { throw AnkrError.transport }
        return try await live.send(request)
    }
}

final class SuiPriceLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testReadOnlyLiveFallbackAgainstIndependentPrimary() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_SUI_QUOTES"] == "1" else {
            throw XCTSkip("Opt-in public SUI quote read; no wallet or transaction")
        }
        let primary = try await SuiMarkets().nativePrice()
        XCTAssertEqual(primary.source, "Coinbase", "Comparison must use independent providers")
        let recovered = try await SuiMarkets(transport: SuiOutageWithLiveFallback()).nativePrice()
        XCTAssertEqual(recovered.source, "DEX Screener"); XCTAssertEqual(recovered.reference, "native")
        let a = try XCTUnwrap(Double(primary.usd)), b = try XCTUnwrap(Double(recovered.usd))
        XCTAssertGreaterThan(a, 0); XCTAssertGreaterThan(b, 0)
        XCTAssertLessThan(abs(a-b)/a, 0.10)
        print("SUI_LIVE_PRICE verified primary=Coinbase fallback=DexScreener tolerance=10percent broadcast=false")
    }
}

private final class SuiQuoteProtocol: URLProtocol, @unchecked Sendable {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var value: [String: Int] = [:]
    }
    private static let counts = Counts()
    static var requestCounts: [String: Int] { counts.lock.withLock { counts.value } }
    override class func canInit(with request: URLRequest) -> Bool {
        ["api.coinbase.com", "api.dexscreener.com"].contains(request.url?.host)
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
            self.client?.urlProtocol(self, didLoad: primary ? Data() : suiPriceFixture)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { }
}

final class SuiPriceSharedTransportTests: XCTestCase, @unchecked Sendable {
    // Isolated process: use the real shared cache, HTTP client and URLSession.
    func testConcurrentAndRepeatedNativePricesShareFallbackAndHonorPrimaryCooldown() async throws {
        func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SuiQuoteProtocol.self]
            return URLSession(configuration: configuration)
        }
        let first = session(), second = session()
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        let one = SuiMarkets(transport: AnkrHTTPTransport(session: first))
        let two = SuiMarkets(transport: AnkrHTTPTransport(session: second))
        async let a = one.nativePrice()
        async let b = two.nativePrice()
        let (left, right) = try await (a, b)
        XCTAssertEqual(left.usd, "3.25"); XCTAssertEqual(right.usd, "3.25")
        _ = try await two.nativePrice()
        XCTAssertEqual(SuiQuoteProtocol.requestCounts, ["api.coinbase.com": 1, "api.dexscreener.com": 1])
    }
}
