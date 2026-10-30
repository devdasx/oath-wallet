import XCTest
import OathDatabase
import OathDiagnostics
import OathTokenImages
@testable import OathMarketData

private actor ThrottledArtworkMetadata: MarketTransport {
    private(set) var calls = 0
    let failure: any Error
    init(_ failure: any Error = MarketDataError.rateLimited) { self.failure = failure }
    func data(from url: URL) async throws -> Data { calls += 1; throw failure }
}
actor PublishedArtworkFeed: ArtworkTransport {
    let data: Data
    let failure: (any Error)?
    private(set) var calls = 0
    init(_ data: Data, failure: (any Error)? = nil) { self.data = data; self.failure = failure }
    func data(from url: URL) async throws -> Data {
        calls += 1
        if let failure { throw failure }
        return data
    }
}

private actor DelayedArtworkCatalog: ArtworkTransport {
    let started: XCTestExpectation
    private var completion: CheckedContinuation<Data, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func data(from url: URL) async throws -> Data {
        await withCheckedContinuation { completion in
            self.completion = completion
            started.fulfill()
        }
    }
    func finish(_ data: Data) { completion?.resume(returning: data); completion = nil }
}

final class RateLimitedArtworkMetadataTests: XCTestCase, @unchecked Sendable {
    private let reference = "0x932e691aa8c8306c4bb0b19f3f00a284371be8ba"
    private let logo = "https://cdn.example.org/flare-token.png"
    private func listing() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": [["chainId": 14, "address": reference,
            "decimals": 18, "logoURI": logo]]])
    }
    func testReportedFlareArtworkRecoversWhileMarketProviderIsThrottled() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let primary = ThrottledArtworkMetadata(), feed = PublishedArtworkFeed(try listing())
        let service = MarketDataService(database: db, transport: primary, artworkCatalog: ArtworkFallbackCatalog(transport: feed))
        let identity = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: 18)!
        let capture = MarketTestDiagnostics.shared, operationID = UUID()
        await OathDiagnostics.$operationID.withValue(operationID) {
            for _ in 0..<3 {
                let sources = await service.sources(for: identity, cachedOnly: false)
                XCTAssertEqual(sources, [logo], "Provider throttling must not prevent the verified token logo from resolving")
            }
        }
        let primaryCalls = await primary.calls, catalogCalls = await feed.calls
        XCTAssertEqual(primaryCalls, 1, "Keep the existing provider cooldown")
        XCTAssertEqual(catalogCalls, 1, "All retries share one public network list")
        let asset = MarketAsset(id: identity.assetID, networkID: "flare", reference: reference, decimals: 18)
        let cachedInformation = try await service.cachedInformation(for: asset)
        XCTAssertNil(cachedInformation, "Artwork must not manufacture market details or token verification")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events(for: operationID).contains(where: { $0.operation == "market_load" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events(for: operationID)
        XCTAssertEqual(events.filter { $0.operation == "market_load" }.count, 1, "Retain the original provider failure")
        XCTAssertFalse(events.contains { $0.operation == "token_metadata" }, "Recovered artwork and cached backoff must not produce repeated failures")
    }
    func testUnlistedArtworkIsNotConfusedWithCatalogFailureOrAnotherToken() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let token = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: 18)!
        let capture = MarketTestDiagnostics.shared
        for row in [
            ["chainId": 1, "address": reference, "logoURI": logo],
            ["chainId": 14, "address": "0x1111111111111111111111111111111111111111", "symbol": "SAME", "logoURI": logo],
            ["chainId": 14, "address": reference, "logoURI": "https://user:private@cdn.example.org/image.png"]
        ] as [[String: Any]] {
            let feed = PublishedArtworkFeed(try JSONSerialization.data(withJSONObject: ["tokens": [row]]))
            let service = MarketDataService(database: db, transport: ThrottledArtworkMetadata(), artworkCatalog: ArtworkFallbackCatalog(transport: feed))
            let id = UUID()
            let sources = await OathDiagnostics.$operationID.withValue(id) { await service.sources(for: token, cachedOnly: false) }
            XCTAssertTrue(sources.isEmpty, "A matching ticker, different chain or unsafe URL must never substitute artwork")
            for _ in 0..<100 {
                if await capture.events(for: id).contains(where: { $0.operation == "market_load" }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let events = await capture.events(for: id)
            XCTAssertEqual(events.filter { $0.operation == "market_load" }.count, 1)
            XCTAssertFalse(events.contains { $0.operation == "token_metadata" })
        }
        let broken = PublishedArtworkFeed(Data("malformed".utf8))
        let service = MarketDataService(database: db, transport: ThrottledArtworkMetadata(), artworkCatalog: ArtworkFallbackCatalog(transport: broken))
        let id = UUID()
        let result = await OathDiagnostics.$operationID.withValue(id) { await service.sources(for: token, cachedOnly: false) }
        XCTAssertTrue(result.isEmpty)
        for _ in 0..<100 {
            if await capture.events(for: id).contains(where: { $0.operation == "token_metadata" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let errors = await capture.events(for: id)
        XCTAssertTrue(errors.contains { $0.operation == "fallback_catalog" })
        XCTAssertTrue(errors.contains { $0.operation == "token_metadata" }, "A failed catalog is not proof of missing optional artwork")
        let report = String(decoding: try JSONEncoder().encode(errors), as: UTF8.self)
        XCTAssertFalse(report.contains(reference)); XCTAssertFalse(report.contains("https://"))
    }

    func testCacheOnlyInvalidMetadataAndCancellationDoNotFetchReplacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let token = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: 18)!
        for failure in [MarketDataError.invalidResponse as any Error, CancellationError(), URLError(.cancelled)] {
            let primary = ThrottledArtworkMetadata(failure), feed = PublishedArtworkFeed(try listing())
            let service = MarketDataService(database: db, transport: primary, artworkCatalog: ArtworkFallbackCatalog(transport: feed))
            let cached = await service.sources(for: token, cachedOnly: true)
            XCTAssertTrue(cached.isEmpty)
            let cachedCalls = await primary.calls; XCTAssertEqual(cachedCalls, 0)
            let result = await service.sources(for: token, cachedOnly: false)
            XCTAssertTrue(result.isEmpty)
            let fallbackCalls = await feed.calls; XCTAssertEqual(fallbackCalls, 0)
        }
    }

    func testRecoveredArtworkDecodesAndSurvivesOfflineResolverRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let primary = ThrottledArtworkMetadata(), feed = PublishedArtworkFeed(try listing())
        let service = MarketDataService(database: db, transport: primary, artworkCatalog: ArtworkFallbackCatalog(transport: feed))
        let imageData = Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect fill='blue' width='16' height='16'/></svg>".utf8)
        let images = folder.appendingPathComponent("images"), identities = folder.appendingPathComponent("identities")
        let imageFeed = PublishedArtworkFeed(imageData)
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: imageFeed), metadata: service, directory: identities)
        let token = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: 18)!
        let result = await resolver.image(for: token, sources: []); XCTAssertNotNil(result)
        let offline = PublishedArtworkFeed(Data(), failure: URLError(.notConnectedToInternet))
        let offlinePrimary = ThrottledArtworkMetadata(URLError(.notConnectedToInternet))
        let restoredService = MarketDataService(database: db, transport: offlinePrimary, artworkCatalog: ArtworkFallbackCatalog(transport: offline))
        let restored = TokenArtworkResolver(loader: ArtworkLoader(directory: images, transport: offline), metadata: restoredService, directory: identities)
        let saved = await restored.image(for: token, sources: []); XCTAssertNotNil(saved)
        let offlineCalls = await offline.calls, metadataCalls = await offlinePrimary.calls
        XCTAssertEqual(offlineCalls, 0); XCTAssertEqual(metadataCalls, 0)
    }

    func testCancellationWhileCatalogLoadsDoesNotReturnLateArtwork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let started = expectation(description: "Shared catalog started")
        let feed = DelayedArtworkCatalog(started: started)
        let service = MarketDataService(database: db, transport: ThrottledArtworkMetadata(), artworkCatalog: ArtworkFallbackCatalog(transport: feed))
        let token = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: 18)!
        let task = Task { await service.sources(for: token, cachedOnly: false) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await feed.finish(try listing())
        let cancelled = await task.value; XCTAssertTrue(cancelled.isEmpty)
        let later = await service.sources(for: token, cachedOnly: false)
        XCTAssertEqual(later, [logo], "Another consumer can still use the shared catalog result")
    }

    func testCancellationWhileCatalogFailsDoesNotRepeatOriginalRateLimit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let started = expectation(description: "Shared catalog started")
        let feed = DelayedArtworkCatalog(started: started), capture = MarketTestDiagnostics.shared
        let service = MarketDataService(database: db, transport: ThrottledArtworkMetadata(), artworkCatalog: ArtworkFallbackCatalog(transport: feed))
        let token = TokenArtworkIdentity(networkID: "flare", reference: reference, decimals: 18)!, id = UUID()
        let task = Task { await OathDiagnostics.$operationID.withValue(id) { await service.sources(for: token, cachedOnly: false) } }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await feed.finish(Data("invalid catalog".utf8))
        let cancelled = await task.value; XCTAssertTrue(cancelled.isEmpty)
        // A later sentinel confirms the shared sink is active for this operation.
        OathDiagnostics.$operationID.withValue(id) {
            OathDiagnostics.record(MarketDataError.invalidResponse, component: "artwork_test", operation: "sentinel")
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.events(for: id).contains(where: { $0.operation == "sentinel" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events(for: id)
        XCTAssertTrue(events.contains { $0.operation == "sentinel" })
        XCTAssertFalse(events.contains { $0.operation == "token_metadata" })
    }

}
