import XCTest
import OathArtworkSource
import OathDiagnostics
@testable import OathTokenImages

private actor BNBArtworkFeed: ArtworkTransport {
    private(set) var calls: [String: Int] = [:]
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        return try await ArtworkURLTransport().data(from: url)
    }
}
final class ReportedBNBArtworkTests: XCTestCase, @unchecked Sendable {
    func testExactReportedAbsentLogoAndExistingBNBLogoWithProductionTransport() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_REPORTED_BNB_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public BNB image/catalog requests; no wallets or credentials")
        }
        let source = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/smartchain/assets/0x6f4A363845c9B10E69E1CEb9c69b4754209a672f/logo.png"
        XCTAssertEqual(String(ArtworkSource.key(source).prefix(12)), "fd1b77f2e21c")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let capture = ArtworkDiagnosticCapture.shared, started = Date(), feed = BNBArtworkFeed()
        OathDiagnostics.configure(file: ArtworkDiagnosticCapture.file, transport: capture)
        let images = folder.appendingPathComponent("images")
        let catalog = ArtworkFallbackCatalog(transport: feed)
        for _ in 0..<3 {
            let loader = ArtworkLoader(directory: images, transport: feed, fallbackCatalog: catalog)
            let result = await OathDiagnostics.$chain.withValue("bnb") { await loader.image(for: [source]) }
            XCTAssertNil(result, "This exact token has no published image; preserve the existing UI fallback")
        }
        let calls = await feed.calls
        XCTAssertEqual(calls[source], 1, "Production HTTP absence must be remembered across relaunches")
        XCTAssertEqual(calls["https://tokens.coingecko.com/binance-smart-chain/all.json"], 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: images.appendingPathComponent(ArtworkSource.key(source) + ".missing").path))
        // Positive live control: published BNB token artwork still downloads,
        // decodes and survives a new loader instance without another request.
        let published = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/smartchain/assets/0x55d398326f99059fF775485246999027B3197955/logo.png"
        let loader = ArtworkLoader(directory: images, transport: feed, fallbackCatalog: catalog)
        let displayed = await loader.image(for: [published]); XCTAssertNotNil(displayed)
        let relaunched = ArtworkLoader(directory: images, transport: feed, fallbackCatalog: catalog)
        let restored = await relaunched.image(for: [published]); XCTAssertNotNil(restored)
        let finalCalls = await feed.calls; XCTAssertEqual(finalCalls[published], 1)
        OathDiagnostics.record(ArtworkError.http(502), component: "artwork_test", operation: "sentinel")
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await capture.since(started).contains(where: { $0.operation == "sentinel" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.since(started)
        XCTAssertTrue(events.contains { $0.operation == "sentinel" })
        XCTAssertFalse(events.contains { $0.component == "network" || $0.component == "artwork" })
        print("REPORTED_BNB_ARTWORK source=fd1b77f2e21c missingRequests=1 relaunches=3 appErrors=0 publishedLogo=decoded+cached")
    }
}
