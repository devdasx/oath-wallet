import XCTest
import OathArtworkSource
import OathTokenImages
import OathDiagnostics
@testable import OathAnkr

private actor SharedArtworkProvider: ArtworkTransport {
    private(set) var calls: [ContinuousClock.Instant] = []
    let failure: (any Error & Sendable)?
    init(failure: (any Error & Sendable)? = nil) { self.failure = failure }
    func data(from url: URL) async throws -> Data {
        calls.append(.now)
        try await Task.sleep(for: .milliseconds(10))
        if let failure { throw failure }
        return Data(#"{"tokens":[]}"#.utf8)
    }
    func response(_ url: URL) async throws -> PublicMarketRequests.Response {
        .init(data: try await data(from: url), status: 200)
    }
}
final class PublicArtworkCatalogTransportTests: XCTestCase, @unchecked Sendable {
    private let first = URL(string: "https://tokens.coingecko.com/linea/all.json")!
    private let second = URL(string: "https://tokens.coingecko.com/ethereum/all.json")!

    func testLiveReportedLineaCatalogSharesDiscoveryResponse() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_SHARED_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in anonymous published Linea token list; no account data")
        }
        let pool = PublicMarketRequests(spacing: .zero)
        let artwork = PublicArtworkCatalogTransport(transport: ArtworkURLTransport(), requests: pool)
        let data = try await artwork.data(from: first)
        struct Catalog: Decodable { struct Token: Decodable { let chainId: Int; let address: String }; let tokens: [Token] }
        let list = try JSONDecoder().decode(Catalog.self, from: data)
        XCTAssertFalse(list.tokens.isEmpty)
        XCTAssertTrue(list.tokens.allSatisfy { $0.chainId == 59144 && $0.address.hasPrefix("0x") })
        let response = try await pool.send(URLRequest(url: first)) {
            XCTFail("Discovery repeated a catalog already loaded for artwork")
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(response.data, data)
        print("SHARED_ARTWORK_CATALOG network=linea tokens=\(list.tokens.count) discoveryReused=true walletRequests=0")
    }
    func testDiscoveryAndArtworkCoalesceOneCatalogAndReuseSharedCache() async throws {
        let provider = SharedArtworkProvider(), pool = PublicMarketRequests(spacing: .zero)
        let artwork = PublicArtworkCatalogTransport(transport: provider, requests: pool)
        let request = URLRequest(url: first), url = first
        async let discovery = pool.send(request) { try await provider.response(url) }
        async let image = artwork.data(from: url)
        let (response, data) = try await (discovery, image)
        XCTAssertEqual(response.data, data)
        _ = try await artwork.data(from: url)
        let calls = await provider.calls; XCTAssertEqual(calls.count, 1)
    }
    func testDifferentNetworkCatalogsShareStartSpacingWithDiscovery() async throws {
        let provider = SharedArtworkProvider(), pool = PublicMarketRequests(spacing: .milliseconds(80))
        let artwork = PublicArtworkCatalogTransport(transport: provider, requests: pool)
        let request = URLRequest(url: first), url = first
        _ = try await pool.send(request) { try await provider.response(url) }
        _ = try await artwork.data(from: second)
        let calls = await provider.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertGreaterThanOrEqual(calls[0].duration(to: calls[1]), .milliseconds(75))
    }
    func testDiscoveryRateLimitStopsArtworkWithoutAnotherRequest() async throws {
        let provider = SharedArtworkProvider(), pool = PublicMarketRequests(spacing: .zero)
        _ = try await pool.send(URLRequest(url: first)) { .init(data: Data(), status: 429, retryAfter: "91") }
        let artwork = PublicArtworkCatalogTransport(transport: provider, requests: pool)
        do { _ = try await artwork.data(from: second); XCTFail("Bypassed provider cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
    }
    func testArtworkRateLimitStopsQueuedDiscoveryAndPreservesRetryAfter() async throws {
        let provider = SharedArtworkProvider(failure: ArtworkRateLimit(retryAfter: "91"))
        let pool = PublicMarketRequests(spacing: .zero)
        let artwork = PublicArtworkCatalogTransport(transport: provider, requests: pool)
        do { _ = try await artwork.data(from: first); XCTFail("Missing rate limit") }
        catch { XCTAssertEqual((error as? ArtworkRateLimit)?.delay, 91) }
        do {
            let url = second
            _ = try await pool.send(URLRequest(url: url)) { try await provider.response(url) }
            XCTFail("Discovery ignored artwork cooldown")
        } catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let calls = await provider.calls; XCTAssertEqual(calls.count, 1)
    }
    func testCachedLargeResponseStillHonorsArtworkLimitAndHTTPFailuresKeepCodes() async throws {
        let provider = SharedArtworkProvider(), pool = PublicMarketRequests(spacing: .zero)
        _ = try await pool.send(URLRequest(url: first)) {
            .init(data: Data(repeating: 0, count: ArtworkSource.byteLimit + 1), status: 200)
        }
        let artwork = PublicArtworkCatalogTransport(transport: provider, requests: pool)
        do { _ = try await artwork.data(from: first); XCTFail("Oversized cache escaped byte limit") }
        catch { XCTAssertEqual(error as? ArtworkError, .oversized) }
        let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
        let unavailable = PublicArtworkCatalogTransport(transport: SharedArtworkProvider(failure: ArtworkError.http(503)),
                                                       requests: PublicMarketRequests(spacing: .zero))
        do { _ = try await unavailable.data(from: second); XCTFail("Missing original HTTP failure") }
        catch { XCTAssertEqual(error as? ArtworkError, .http(503)) }
    }
    func testCancellationAndInvalidSourcesDoNotReachNetworkOrPoisonHost() async throws {
        let provider = SharedArtworkProvider(), pool = PublicMarketRequests(spacing: .zero)
        let artwork = PublicArtworkCatalogTransport(transport: provider, requests: pool)
        let invalid = URL(string: "https://user:password@tokens.coingecko.com/linea/all.json")!
        do { _ = try await artwork.data(from: invalid); XCTFail("Accepted credentials in artwork URL") }
        catch { XCTAssertEqual(error as? ArtworkError, .invalidSource) }
        let canceled = PublicArtworkCatalogTransport(transport: SharedArtworkProvider(failure: CancellationError()), requests: pool)
        do { _ = try await canceled.data(from: first); XCTFail("Cancellation was swallowed") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await artwork.data(from: second)
        let calls = await provider.calls; XCTAssertEqual(calls.count, 1)
    }
}
