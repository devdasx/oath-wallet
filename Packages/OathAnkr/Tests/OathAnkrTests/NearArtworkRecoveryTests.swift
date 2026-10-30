import XCTest
import OathArtworkSource
import OathTokenImages
@testable import OathAnkr

private actor NearArtworkFeed: AnkrTransport {
    let fixture: Data?
    private(set) var calls = 0
    init(fixture: Data?) { self.fixture = fixture }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "api.geckoterminal.com",
              request.url?.path.hasPrefix("/api/v2/networks/near/tokens/multi/") == true,
              request.httpBody == nil else { throw TokenDiscoveryError.unavailable }
        calls += 1
        if let fixture { return (fixture, 200) }
        return try await AnkrHTTPTransport().send(request)
    }
}
private actor NearArtworkImages: ArtworkTransport {
    let offline: Bool
    private(set) var requests = 0
    private(set) var guesses = 0
    init(offline: Bool = false) { self.offline = offline }
    func data(from url: URL) async throws -> Data {
        requests += 1
        if url.host == "raw.githubusercontent.com" { guesses += 1; throw URLError(.resourceUnavailable) }
        guard !offline else { throw URLError(.notConnectedToInternet) }
        return try await ArtworkURLTransport().data(from: url)
    }
}
final class NearArtworkRecoveryTests: XCTestCase, @unchecked Sendable {
    private let reference = "eth-0xdac17f958d2ee523a2206206994597c13d831ec7.omft.near"
    private var source: String { "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/near/assets/" + reference + "/logo.png" }
    private var entry: TokenDiscoveryEntry {
        .init(network: "near", reference: reference, coinID: "near-intents-bridged-usdt", name: "USDT", symbol: "USDT", decimals: 6, logo: nil)
    }
    private func fixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "near-reported-artwork", withExtension: "json", subdirectory: "Fixtures")))
    }
    func testReportedContractUsesBatchAndCachesWithoutRequestingCoinMetadata() async throws {
        XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), "38ed0735233c")
        let transport = NearArtworkFeed(fixture: try fixture()), batch = TokenBatchArtwork(transport: NearArtworkFeed(fixture: try fixture()), spacing: .zero)
        // Independent clients also support this chain; provider quotas remain
        // shared by AnkrHTTPTransport rather than this test fixture transport.
        let catalog = TokenBatchArtwork(transport: transport, spacing: .zero)
        await catalog.prefetch([entry, entry])
        let first = await catalog.source(for: entry, cachedOnly: false)
        XCTAssertNotNil(first)
        let cached = await catalog.source(for: entry, cachedOnly: true)
        XCTAssertEqual(cached, first)
        let second = await batch.source(for: entry, cachedOnly: false)
        XCTAssertEqual(second, first)
        let calls = await transport.calls; XCTAssertEqual(calls, 1)
    }
    func testWrongNetworkOrDifferentContractCannotSupplyArtwork() throws {
        let data = try fixture()
        XCTAssertEqual(try TokenBatchArtwork.decode(data, network: "near", requested: [reference]).count, 1)
        XCTAssertThrowsError(try TokenBatchArtwork.decode(data, network: "xrpl", requested: [reference]))
        XCTAssertThrowsError(try TokenBatchArtwork.decode(data, network: "near", requested: ["usdt.tether-token.near"]))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try XCTUnwrap((original["data"] as? [[String: Any]])?.first)
        let duplicate = try JSONSerialization.data(withJSONObject: ["data": [row, row]])
        XCTAssertThrowsError(try TokenBatchArtwork.decode(duplicate, network: "near", requested: [reference, "usdt.tether-token.near"]))
    }
    func testLiveReportedImageColdSearchColdHoldingsAndOfflineRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in exact reported public NEAR token image; no wallet requests")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for decimals: Int? in [nil, 6] {
            let mode = folder.appendingPathComponent(decimals == nil ? "search" : "holdings")
            let transport = NearArtworkFeed(fixture: nil), images = NearArtworkImages()
            let catalog = TokenDiscoveryCatalog(transport: transport, directory: mode.appendingPathComponent("catalog"))
            let identity = try XCTUnwrap(TokenArtworkIdentity(networkID: "near", reference: reference, decimals: decimals))
            let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: mode.appendingPathComponent("images"),
                transport: images, fallbackCatalog: ArtworkFallbackCatalog(transport: images)), metadata: catalog,
                directory: mode.appendingPathComponent("identities"))
            let image = await resolver.image(for: identity, sources: [source])
            XCTAssertNotNil(image)
            let calls = await transport.calls; XCTAssertEqual(calls, 1)
            let guesses = await images.guesses; XCTAssertEqual(guesses, 0)
            let offline = NearArtworkImages(offline: true)
            let restored = TokenArtworkResolver(loader: ArtworkLoader(directory: mode.appendingPathComponent("images"),
                transport: offline, fallbackCatalog: ArtworkFallbackCatalog(transport: offline)), metadata: catalog,
                directory: mode.appendingPathComponent("identities"))
            let saved = await restored.image(for: identity, sources: [])
            XCTAssertNotNil(saved)
            let offlineCalls = await offline.requests; XCTAssertEqual(offlineCalls, 0)
        }
        print("NEAR_ARTWORK_RECOVERY tokens=1 coldSearch=1 coldHoldings=1 offline=2 guessedRequests=0 walletRequests=0")
    }
}
