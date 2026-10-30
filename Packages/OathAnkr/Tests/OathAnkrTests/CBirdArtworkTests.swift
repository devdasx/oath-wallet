import XCTest
import OathTokenImages
@testable import OathAnkr

final class CBirdArtworkTests: XCTestCase {
    private let reference = "4342495244000000000000000000000000000000.rHcU3JWTp7fnea3xgvbV8pCbEp9S3HjSUz"
    private let image = "https://coin-images.coingecko.com/coins/images/55018/small/IMG_1991.jpeg?1752995575"

    func testBundledExactIssuerArtworkResolvesOffline() async throws {
        let catalog = TokenDiscoveryCatalog(transport: CBirdOfflineTransport())
        let entries = await catalog.search(reference, networks: ["xrpl"])
        let entry = try XCTUnwrap(entries.first { $0.reference == reference })
        XCTAssertEqual(entry.coinID, "common-bird")
        XCTAssertEqual(entry.logo, image)
        XCTAssertEqual(entry.decimals, 96, "Artwork must not change the existing XRPL amount scale")
        let selected = try await catalog.resolve(network: "xrpl", reference: reference)
        XCTAssertEqual(selected.logo, image)
    }

    func testArtworkDoesNotMatchAnotherIssuerOrNetwork() async throws {
        let catalog = TokenDiscoveryCatalog(transport: CBirdOfflineTransport())
        let other = "4342495244000000000000000000000000000000.rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        let matches = await catalog.search(other, networks: ["xrpl"])
        XCTAssertFalse(matches.contains { $0.logo == image })
        let wrongChain = await catalog.search(reference, networks: ["ethereum"])
        XCTAssertTrue(wrongChain.isEmpty)
    }

    func testPublishedImageDownloadsAndDecodes() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CBIRD_ARTWORK_LIVE"] == "1" else { throw XCTSkip("Opt-in public artwork read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ArtworkLoader(directory: folder)
        let result = await loader.image(for: [image])
        XCTAssertNotNil(result)
        let cached = await loader.cached(for: [image])
        XCTAssertNotNil(cached)
    }
}

private struct CBirdOfflineTransport: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { throw URLError(.notConnectedToInternet) }
}
