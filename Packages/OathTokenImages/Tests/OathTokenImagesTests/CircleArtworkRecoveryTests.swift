import XCTest
import OathArtworkSource
@testable import OathTokenImages

private let legacyCircleIcon = "https://circle.com/usdc-icon"
private let suiUSDC = "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"
private struct CircleMetadata: TokenArtworkMetadata {
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] { [legacyCircleIcon] }
}
private actor CircleArtworkFeed: ArtworkTransport {
    let live: Bool
    private(set) var calls: [String] = []
    init(live: Bool = false) { self.live = live }
    func data(from url: URL) async throws -> Data {
        calls.append(url.absoluteString)
        if url.absoluteString == legacyCircleIcon { throw ArtworkError.http(403) }
        if live { return try await ArtworkURLTransport().data(from: url) }
        if url.host == "tokens.coingecko.com" {
            return try JSONSerialization.data(withJSONObject: ["tokens": [[
                "chainId": NSNull(), "address": suiUSDC, "logoURI": "https://cdn.example.org/usdc.svg"
            ]]])
        }
        if url.absoluteString == "https://cdn.example.org/usdc.svg" {
            return Data("<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16' fill='#2775ca'/></svg>".utf8)
        }
        throw ArtworkError.http(404)
    }
}
final class CircleArtworkRecoveryTests: XCTestCase, @unchecked Sendable {
    func testRetiredCircleIconUsesExactIdentityAndSurvivesRelaunch() async throws {
        try await verify(live: false)
    }
    func testLiveCircleReplacementDecodesAndSurvivesRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_CIRCLE_ARTWORK_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public token list and image reads")
        }
        try await verify(live: true)
    }
    private func verify(live: Bool) async throws {
        XCTAssertEqual(String(ArtworkSource.key(legacyCircleIcon).prefix(12)), "7f9f3fec7373")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = CircleArtworkFeed(live: live)
        func resolver(_ transport: CircleArtworkFeed) -> TokenArtworkResolver {
            TokenArtworkResolver(loader: ArtworkLoader(directory: directory.appendingPathComponent("images"),
                transport: transport, fallbackCatalog: ArtworkFallbackCatalog(transport: transport)),
                metadata: CircleMetadata(), directory: directory.appendingPathComponent("identities"))
        }
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "sui", reference: suiUSDC, decimals: 6))
        let image = await resolver(feed).image(for: token, sources: [legacyCircleIcon])
        XCTAssertNotNil(image)
        let calls = await feed.calls
        XCTAssertFalse(calls.contains(legacyCircleIcon), "Do not retry the known retired image before its verified replacement")
        let offline = CircleArtworkFeed()
        let restored = await resolver(offline).image(for: token, sources: [legacyCircleIcon])
        XCTAssertNotNil(restored)
        let offlineCalls = await offline.calls
        XCTAssertTrue(offlineCalls.isEmpty, "Successful identity artwork must persist across launches")
    }
    func testCircleURLCannotAssignUSDCArtworkToAnotherToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = CircleArtworkFeed()
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: directory, transport: feed,
            fallbackCatalog: ArtworkFallbackCatalog(transport: feed)), metadata: CircleMetadata(),
            directory: directory.appendingPathComponent("identity"))
        let reference = "0x" + String(repeating: "0", count: 63) + "2::other::USDC"
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "sui", reference: reference, decimals: 6))
        let image = await resolver.image(for: token, sources: [legacyCircleIcon])
        XCTAssertNil(image)
        let calls = await feed.calls
        XCTAssertTrue(calls.contains("https://tokens.coingecko.com/sui/all.json"))
        XCTAssertFalse(calls.contains("https://cdn.example.org/usdc.svg"))
    }

    func testSavedLegacyIdentityWithEvictedBytesMigratesBeforeDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identities = directory.appendingPathComponent("identities")
        try FileManager.default.createDirectory(at: identities, withIntermediateDirectories: true)
        let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "sui", reference: suiUSDC, decimals: 6))
        struct SavedIdentity: Encodable { let source: String; let saved: Date }
        try PropertyListEncoder().encode(SavedIdentity(source: legacyCircleIcon, saved: .now))
            .write(to: identities.appendingPathComponent(token.cacheKey + ".plist"))
        let feed = CircleArtworkFeed()
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: directory.appendingPathComponent("images"),
            transport: feed, fallbackCatalog: ArtworkFallbackCatalog(transport: feed)),
            metadata: CircleMetadata(), directory: identities)
        let image = await resolver.image(for: token, sources: [])
        XCTAssertNotNil(image)
        let calls = await feed.calls
        XCTAssertFalse(calls.contains(legacyCircleIcon))
    }
}
