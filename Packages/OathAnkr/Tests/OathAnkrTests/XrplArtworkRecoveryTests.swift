import XCTest
import OathArtworkSource
import OathTokenImages
@testable import OathAnkr

private struct XrplArtworkSample: Decodable {
    let reference: String
    let coinID: String
    let url: String
    let hash: String
    var hasImage: Bool { ["societe-generale-forge-eurcv", "crypto-trading-fund"].contains(coinID) }
    var entry: TokenDiscoveryEntry {
        .init(network: "xrpl", reference: reference, coinID: coinID, name: coinID,
              symbol: "fixture", decimals: XrplIdentity.issuedScale, logo: nil)
    }
}
private actor XrplArtworkFeed: AnkrTransport {
    let fixture: Data?
    private(set) var calls = 0
    init(fixture: Data?) { self.fixture = fixture }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        // The live check admits only public token metadata, never accounts,
        // private credentials, transactions or the per-coin fallback API.
        guard request.url?.host == "api.geckoterminal.com",
              request.url?.path.hasPrefix("/api/v2/networks/xrpl/tokens/multi/") == true,
              request.httpBody == nil else { throw TokenDiscoveryError.unavailable }
        calls += 1
        if let fixture { return (fixture, 200) }
        return try await AnkrHTTPTransport().send(request)
    }
}
private actor XrplImageFeed: ArtworkTransport {
    let offline: Bool
    private(set) var calls = 0
    init(offline: Bool = false) { self.offline = offline }
    func data(from url: URL) async throws -> Data {
        calls += 1
        guard !offline, url.host != "raw.githubusercontent.com" else { throw URLError(.resourceUnavailable) }
        return try await ArtworkURLTransport().data(from: url)
    }
}
final class XrplArtworkRecoveryTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func samples() throws -> [XrplArtworkSample] {
        try JSONDecoder().decode([XrplArtworkSample].self, from: fixture("xrpl-reported-artwork-identities"))
    }
    func testReportedXrplTokensBatchAndCacheMissingOptionalImages() async throws {
        let samples = try samples(), transport = XrplArtworkFeed(fixture: try fixture("xrpl-reported-artwork"))
        let batch = TokenBatchArtwork(transport: transport, spacing: .zero)
        await batch.prefetch(samples.map(\.entry))
        for sample in samples {
            XCTAssertEqual(String(ArtworkSource.key(sample.url).prefix(12)), sample.hash)
            let source = await batch.source(for: sample.entry, cachedOnly: false)
            XCTAssertEqual(source != nil, sample.hasImage, sample.coinID)
            let cached = await batch.source(for: sample.entry, cachedOnly: true)
            XCTAssertEqual(cached, source)
        }
        // Missing optional images remain nil and do not repeat the request.
        for sample in samples { _ = await batch.source(for: sample.entry, cachedOnly: false) }
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }
    func testIssuedCurrencyAndIssuerMustBothMatchAndRowsCannotConflict() throws {
        let samples = try samples(), data = try fixture("xrpl-reported-artwork")
        let requested = Set(samples.map(\.reference))
        let images = try TokenBatchArtwork.decode(data, network: "xrpl", requested: requested)
        XCTAssertEqual(images.count, 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try XCTUnwrap(object["data"] as? [[String: Any]])
        func encoded(_ rows: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["data": rows]) }
        var row = rows[0]
        row["id"] = "near_" + samples[0].reference
        XCTAssertThrowsError(try TokenBatchArtwork.decode(encoded([row]), network: "xrpl", requested: requested))
        let parts = samples[0].reference.split(separator: ".")
        let differentIssuer = String(parts[0]) + "." + samples[1].reference.split(separator: ".").last!
        var attributes = try XCTUnwrap(rows[0]["attributes"] as? [String: Any])
        attributes["address"] = differentIssuer
        row["id"] = "xrpl_" + differentIssuer; row["attributes"] = attributes
        XCTAssertThrowsError(try TokenBatchArtwork.decode(encoded([row]), network: "xrpl", requested: requested))
        XCTAssertThrowsError(try TokenBatchArtwork.decode(encoded([rows[0], rows[0]]), network: "xrpl", requested: requested))
        object["data"] = [rows[0]]
        XCTAssertThrowsError(try TokenBatchArtwork.decode(JSONSerialization.data(withJSONObject: object), network: "near", requested: requested))
    }
    func testLiveReportedImagesResolveForSearchAndSavedHoldingsThenReloadOffline() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_XRPL_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in exact reported public XRP token artwork; no wallet requests")
        }
        let samples = try samples().filter(\.hasImage)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Each mode starts cold; a successful search must not mask a broken
        // first lookup for an already-saved holding with a known amount scale.
        for decimals: Int? in [nil, XrplIdentity.issuedScale] {
            let mode = folder.appendingPathComponent(decimals == nil ? "search" : "holdings")
            let transport = XrplArtworkFeed(fixture: nil), images = XrplImageFeed()
            let catalog = TokenDiscoveryCatalog(transport: transport, directory: mode.appendingPathComponent("catalog"))
            let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: mode.appendingPathComponent("images"),
                transport: images, fallbackCatalog: ArtworkFallbackCatalog(transport: images)), metadata: catalog,
                directory: mode.appendingPathComponent("identities"))
            for sample in samples {
                let identity = try XCTUnwrap(TokenArtworkIdentity(networkID: "xrpl", reference: sample.reference, decimals: decimals))
                let image = await resolver.image(for: identity, sources: [sample.url])
                XCTAssertNotNil(image, sample.coinID)
            }
            let count = await transport.calls; XCTAssertEqual(count, 2)
            let offline = XrplImageFeed(offline: true)
            let restored = TokenArtworkResolver(loader: ArtworkLoader(directory: mode.appendingPathComponent("images"),
                transport: offline, fallbackCatalog: ArtworkFallbackCatalog(transport: offline)), metadata: catalog,
                directory: mode.appendingPathComponent("identities"))
            for sample in samples {
                let identity = try XCTUnwrap(TokenArtworkIdentity(networkID: "xrpl", reference: sample.reference, decimals: decimals))
                let image = await restored.image(for: identity, sources: [])
                XCTAssertNotNil(image, sample.coinID)
            }
            let offlineRequests = await offline.calls; XCTAssertEqual(offlineRequests, 0)
        }
        print("XRPL_ARTWORK_RECOVERY tokens=2 search=2 holdings=2 offline=4 guessedRequests=0 walletRequests=0")
    }
}
