import XCTest
import OathDatabase
import OathTokenImages
@testable import OathMarketData

private actor ArtworkMarketFeed: MarketTransport {
    let replies: [String: Data]
    var calls = 0
    init(_ replies: [String: Data] = [:]) { self.replies = replies }
    func data(from url: URL) async throws -> Data {
        calls += 1
        guard let reply = replies[url.path] else { throw MarketDataError.notListed }
        return reply
    }
}

final class TokenArtworkMetadataTests: XCTestCase, @unchecked Sendable {
    func testEveryContractSearchNetworkUsesSameValidatedLogoAsDetailsAndReusesSavedMetadata() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        for (network, platform) in MarketIdentity.geckoPlatforms.sorted(by: { $0.key < $1.key }) {
            let reference = network == "solana" ? "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v" :
                network == "tron" ? "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t" :
                network == "thorchain" ? "x/ruji" : "0x1234567890abcdef1234567890abcdef12345678"
            let identity = try XCTUnwrap(TokenArtworkIdentity(networkID: network, reference: reference, decimals: 6))
            let asset = MarketAsset(id: identity.assetID, networkID: network, reference: reference, decimals: 6)
            let logo = "https://coin-images.coingecko.com/coins/images/1/large/\(network).png"
            let data = try JSONSerialization.data(withJSONObject: ["id": "test-token", "name": "Test Token", "symbol": "TST",
                "detail_platforms": [platform: ["contract_address": reference, "decimal_place": 6]], "image": ["large": logo]])
            let feed = ArtworkMarketFeed([try MarketIdentity.informationURL(for: asset).path: data])
            let service = MarketDataService(database: db, transport: feed)
            let before = await service.sources(for: identity, cachedOnly: true)
            XCTAssertTrue(before.isEmpty, network)
            let sources = await service.sources(for: identity, cachedOnly: false)
            let detail = try await service.information(for: asset)
            XCTAssertEqual(sources, [logo], network)
            XCTAssertEqual(sources, [detail.value.imageURL!], network)
            let reopened = MarketDataService(database: db, transport: ArtworkMarketFeed())
            let saved = await reopened.sources(for: identity, cachedOnly: true)
            XCTAssertEqual(saved, sources, network)
            let requests = await feed.calls
            XCTAssertEqual(requests, 1, network)
            let wrongDecimals = TokenArtworkIdentity(networkID: network, reference: reference, decimals: 18)!
            let wrongSources = await service.sources(for: wrongDecimals, cachedOnly: false)
            XCTAssertTrue(wrongSources.isEmpty, "Identity/decimals mismatch must not supply artwork")
        }
    }

    func testNativeMetadataAdaptersShareSavedTokenLogosWithoutNewNetworkRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        for network in ["aptos", "sui", "near", "ton", "xrpl", "stellar"] {
            let reference = "PublicCaseSensitiveToken"
            let logo = "https://cdn.example.org/\(network).svg"
            let identity = TokenArtworkIdentity(networkID: network, reference: reference, decimals: 6)!
            let bytes = try JSONSerialization.data(withJSONObject: ["reference": reference, "name": "Token", "symbol": "TST", "decimals": 6, "logo": logo])
            try await db.saveMarketCache(.init(key: network + ".token." + reference, source: network, payload: bytes, fetchedAt: 123))
            let feed = ArtworkMarketFeed(), service = MarketDataService(database: db, transport: feed)
            let cached = await service.sources(for: identity, cachedOnly: true)
            let fresh = await service.sources(for: identity, cachedOnly: false)
            XCTAssertEqual(cached, [logo], network); XCTAssertEqual(fresh, cached, network)
            let calls = await feed.calls
            XCTAssertEqual(calls, 0, network)
            let wrongCase = TokenArtworkIdentity(networkID: network, reference: reference.lowercased(), decimals: 6)!
            let wrong = await service.sources(for: wrongCase, cachedOnly: true)
            XCTAssertTrue(wrong.isEmpty, network)
        }
    }

    func testLiveTaikoAndThorchainMetadataResolvesExactPublishedTokenIdentity() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_TOKEN_METADATA"] == "1" else {
            throw XCTSkip("Opt-in public token metadata; no wallet or credentials")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let service = MarketDataService(database: db)
        for token in [
            TokenArtworkIdentity(networkID: "taiko", reference: "0xa9d23408b9ba935c230493c40c73824df71a0975", decimals: 18)!,
            TokenArtworkIdentity(networkID: "thorchain", reference: "x/ruji", decimals: 8)!
        ] {
            let sources = await service.sources(for: token, cachedOnly: false)
            XCTAssertFalse(sources.isEmpty, token.networkID)
            let cached = await service.sources(for: token, cachedOnly: true)
            XCTAssertEqual(sources, cached)
        }
    }
}
