import XCTest
@testable import OathTokenImages

private actor TaikoPublicArtwork: ArtworkTransport {
    private(set) var calls: [String: Int] = [:]
    let offline: Bool
    init(offline: Bool = false) { self.offline = offline }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        if offline { throw ArtworkError.http(503) }
        return try await ArtworkURLTransport().data(from: url)
    }
}

private actor TaikoNoPerCoinMetadata: TokenArtworkMetadata {
    private(set) var requests = 0
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if !cachedOnly { requests += 1 }
        return []
    }
}

final class TaikoArtworkLiveTests: XCTestCase, @unchecked Sendable {
    func testLiveTaikoPublishedLogosDecodeAndSurviveOfflineRelaunch() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_TAIKO_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public Taiko registry and images; no wallets or credentials")
        }
        // Canonical bridge tokens, Stargate bridge tokens, wrapped ETH and
        // Taiko itself. Public contract identity is distinct from its ticker.
        let contracts = [
            "0x07d83526730c7438048d55a4fc0b850e2aab6f0b",
            "0x2def195713cf4a606b49d07e520e22c17899a736",
            "0xa51894664a773981c6c112c43ce576f315d5b1b6",
            "0x19e26b0638bf63aa9fa4d14c6baf8d52ebe86c5c",
            "0x9c2dc7377717603eb92b2655c5f2e7997a4945bd",
            "0xa9d23408b9ba935c230493c40c73824df71a0975"
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = TaikoPublicArtwork(), metadata = TaikoNoPerCoinMetadata()
        let resolver = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("images"),
            transport: transport, fallbackCatalog: ArtworkFallbackCatalog(transport: transport)),
            metadata: metadata, directory: dir.appendingPathComponent("identities"))
        let identities = contracts.map { TokenArtworkIdentity(networkID: "taiko", reference: $0)! }
        let decoded = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for identity in identities {
                group.addTask {
                    let guess = "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/taiko/assets/\(identity.reference)/logo.png"
                    return await resolver.image(for: identity, sources: [guess]) != nil
                }
            }
            var count = 0; for await value in group { if value { count += 1 } }; return count
        }
        XCTAssertEqual(decoded, identities.count)
        let calls = await transport.calls
        XCTAssertEqual(calls["https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/167000.json"], 1)
        XCTAssertFalse(calls.keys.contains { $0.contains("tokens.coingecko.com") || $0.contains("blockchains/taiko/assets/") })
        let perCoin = await metadata.requests; XCTAssertEqual(perCoin, 0)
        let offline = TaikoPublicArtwork(offline: true)
        let relaunched = TokenArtworkResolver(loader: ArtworkLoader(directory: dir.appendingPathComponent("images"),
            transport: offline, fallbackCatalog: ArtworkFallbackCatalog(transport: offline)),
            metadata: TaikoNoPerCoinMetadata(), directory: dir.appendingPathComponent("identities"))
        for identity in identities {
            let cached = await relaunched.image(for: identity, sources: [])
            XCTAssertNotNil(cached)
        }
        let offlineCalls = await offline.calls; XCTAssertTrue(offlineCalls.isEmpty)
    }
}
