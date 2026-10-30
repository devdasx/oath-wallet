import XCTest
import OathAnkr
import OathDatabase
import OathDiagnostics
import OathTokenImages
@testable import OathMarketData

private struct LimitedFlareMarketFeed: MarketTransport {
    func data(from url: URL) async throws -> Data { throw MarketDataError.rateLimited }
}
private actor LiveFlareArtworkFeed: ArtworkTransport {
    private(set) var calls = 0
    let live: Bool
    init(live: Bool = true) { self.live = live }
    func data(from url: URL) async throws -> Data {
        calls += 1
        guard live else { throw URLError(.notConnectedToInternet) }
        return try await PublicArtworkCatalogTransport().data(from: url)
    }
}

final class FlareArtworkLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testPublicFlareCatalogRecoversDuringInjectedMarketRateLimit() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_FLARE_ARTWORK_RECOVERY"] == "1" else {
            throw XCTSkip("Opt-in public Flare catalog and logo downloads; market 429 is injected, no wallets or credentials")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = LiveFlareArtworkFeed()
        let service = MarketDataService(database: db, transport: LimitedFlareMarketFeed(), artworkCatalog: ArtworkFallbackCatalog(transport: feed))
        let samples: [(String, Int, Bool)] = [
            ("0x1bac2dbc609ca356b0a7d99af5f7f160fd84a8df", 18, false),
            ("0x282b88514a52fcadcd92b742745398f3574697d4", 18, false),
            ("0x64cb9be6323c7a2ce39773674f380da30663bae4", 6, false),
            ("0x6c1490729ce19e809cf9f7e3e223c0490833de02", 18, false),
            ("0x932e691aa8c8306c4bb0b19f3f00a284371be8ba", 18, true)
        ]
        let capture = MarketTestDiagnostics.shared, id = UUID()
        let images = folder.appendingPathComponent("images"), identities = folder.appendingPathComponent("identities")
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: images), metadata: service, directory: identities)
        for (reference, decimals, listed) in samples {
            let token = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: decimals)!
            let sources = await OathDiagnostics.$operationID.withValue(id) { await service.sources(for: token, cachedOnly: false) }
            XCTAssertEqual(!sources.isEmpty, listed, reference)
            if listed {
                let image = await resolver.image(for: token, sources: []); XCTAssertNotNil(image)
                let offline = LiveFlareArtworkFeed(live: false)
                let restoredService = MarketDataService(database: db, transport: LimitedFlareMarketFeed(), artworkCatalog: ArtworkFallbackCatalog(transport: offline))
                let restored = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: offline), metadata: restoredService, directory: identities)
                let cached = await restored.image(for: token, sources: []); XCTAssertNotNil(cached)
                let offlineCalls = await offline.calls; XCTAssertEqual(offlineCalls, 0)
            }
        }
        let requests = await feed.calls; XCTAssertEqual(requests, 1, "All Flare identities share one public catalog request")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events(for: id).filter({ $0.operation == "market_load" }).count == samples.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events(for: id)
        XCTAssertEqual(events.filter { $0.operation == "market_load" }.count, samples.count)
        XCTAssertFalse(events.contains { $0.operation == "token_metadata" || $0.operation == "fallback_catalog" })
        print("FLARE_ARTWORK_LIVE marketRateLimit=injected publicCatalogRequests=1 publishedLogo=decoded+offline unlistedTokens=4 repeatedArtworkFailures=0")
    }
}
