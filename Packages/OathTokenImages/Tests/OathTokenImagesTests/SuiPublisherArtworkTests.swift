import XCTest
import OathArtworkSource
@testable import OathTokenImages

private struct SuiPublisherMetadata: TokenArtworkMetadata {
    let stale: String
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] { [stale] }
}

private actor SuiPublisherFeed: ArtworkTransport {
    let live: Bool
    var calls: [URL] = []
    init(live: Bool) { self.live = live }
    func data(from url: URL) async throws -> Data {
        calls.append(url)
        if live { return try await ArtworkURLTransport().data(from: url) }
        if url.host == "tokens.coingecko.com" {
            let rows = SuiPublisherArtworkTests.samples.enumerated().map { index, sample in
                ["address": sample.coinType, "logoURI": "https://cdn.example.org/coin-\(index).svg"]
            }
            return try JSONSerialization.data(withJSONObject: ["tokens": rows])
        }
        if url.host == "cdn.example.org" {
            return Data("<svg xmlns='http://www.w3.org/2000/svg' width='8' height='8'><rect width='8' height='8' fill='red'/></svg>".utf8)
        }
        throw ArtworkError.http(url.host == "miucoin.io" ? 403 : 404)
    }
}

final class SuiPublisherArtworkTests: XCTestCase, @unchecked Sendable {
    fileprivate static let samples = [
        (coinType: "0x32a976482bf4154961bf20bfa3567a80122fdf8e8f8b28d752b609d8640f7846::miu::MIU", decimals: 3,
         stale: "https://miucoin.io/favicon.ico", hash: "1d11ee60c04a"),
        (coinType: "0xe6b9e1033c72084ad01db37c77778ca53b9c4ebb263f28ffbfed39f4d5fd5057::win::WIN", decimals: 9,
         stale: "https://winx.io/WIN.svg", hash: "82e7049736ff")
    ]

    func testBothReportedPublisherImagesRecoverByCoinType() async throws { try await check(live: false) }

    func testUnlistedCoinCannotBorrowPublishedImageByRepeatingPublisherURL() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let feed = SuiPublisherFeed(live: false), stale = Self.samples[0].stale
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: folder.appendingPathComponent("images"),
            transport: feed, fallbackCatalog: ArtworkFallbackCatalog(transport: feed)), metadata: SuiPublisherMetadata(stale: stale),
            directory: folder.appendingPathComponent("identities"))
        let other = "0x" + String(repeating: "a", count: 64) + "::miu::MIU"
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "sui", reference: other, decimals: 3))
        let image = await resolver.image(for: token, sources: [stale])
        XCTAssertNil(image)
        let calls = await feed.calls
        XCTAssertFalse(calls.contains { $0.host == "cdn.example.org" })
    }

    func testLivePublishedImagesDecodeAndReopenOffline() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SUI_PUBLISHER_IMAGES_LIVE"] == "1" else {
            throw XCTSkip("Public Sui token list and image reads")
        }
        try await check(live: true)
    }

    private func check(live: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let feed = SuiPublisherFeed(live: live)
        for (index, sample) in Self.samples.enumerated() {
            XCTAssertEqual(String(ArtworkSource.key(sample.stale).prefix(12)), sample.hash)
            let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "sui", reference: sample.coinType, decimals: sample.decimals))
            func resolver(_ feed: SuiPublisherFeed) -> TokenArtworkResolver {
                TokenArtworkResolver(loader: ArtworkLoader(directory: root.appendingPathComponent("images"),
                    transport: feed, fallbackCatalog: ArtworkFallbackCatalog(transport: feed)),
                    metadata: SuiPublisherMetadata(stale: sample.stale), directory: root.appendingPathComponent("identities"))
            }
            let image = await resolver(feed).image(for: token, sources: [sample.stale])
            XCTAssertNotNil(image)
            let calls = await feed.calls
            XCTAssertFalse(calls.contains { $0.absoluteString == sample.stale })
            if !live { XCTAssertTrue(calls.contains { $0.absoluteString == "https://cdn.example.org/coin-\(index).svg" }) }
            let offline = SuiPublisherFeed(live: false)
            let cached = await resolver(offline).image(for: token, sources: [])
            XCTAssertNotNil(cached)
            let offlineCalls = await offline.calls
            XCTAssertTrue(offlineCalls.isEmpty)
        }
    }
}
