import XCTest
@testable import OathTokenImages

private let basePrimary = "https://tokens.coingecko.com/base/all.json"
private let baseSecondary = "https://raw.githubusercontent.com/gluexprotocol/tokens_registry/main/registry/8453.json"
private let baseContract = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
private let baseLogo = "https://cdn.example.org/usdc.png"
private func baseSource(_ contract: String = baseContract) -> String {
    "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/base/assets/\(contract)/logo.png"
}
private func baseRows(_ contracts: [String], chain: Int = 8453, logo: String = baseLogo) -> [[String: Any]] {
    contracts.map { ["chainId": chain, "address": $0, "logoURI": logo] }
}

private actor BaseCatalogFeed: ArtworkTransport {
    enum Reply: Sendable { case bytes(Data), limited, unavailable, cancelled }
    var replies: [String: Reply]
    private(set) var calls: [String: Int] = [:]
    init(_ replies: [String: Reply]) { self.replies = replies }
    func set(_ reply: Reply, for url: String) { replies[url] = reply }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        try await Task.sleep(for: .milliseconds(10))
        switch replies[url.absoluteString] ?? .unavailable {
        case .bytes(let data): return data
        case .limited: throw ArtworkRateLimit(retryAfter: "120")
        case .unavailable: throw ArtworkError.http(503)
        case .cancelled: throw URLError(.cancelled)
        }
    }
}

final class BaseArtworkRecoveryTests: XCTestCase, @unchecked Sendable {
    func testRateLimitedAndUnavailablePrimaryRecoverOneSharedExactContractList() async throws {
        let contracts = (1...12).map { "0x" + String(format: "%040x", $0) }
        let rows = baseRows(contracts) + baseRows([contracts[0]], chain: 1, logo: "https://cdn.example.org/wrong.png")
        for failure in [BaseCatalogFeed.Reply.limited, .unavailable] {
            let feed = BaseCatalogFeed([basePrimary: failure,
                baseSecondary: .bytes(try JSONSerialization.data(withJSONObject: rows))])
            let catalog = ArtworkFallbackCatalog(transport: feed)
            let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
                for contract in contracts { group.addTask { await catalog.sources(for: baseSource(contract)) } }
                var results: [[String]] = []; for await value in group { results.append(value) }; return results
            }
            XCTAssertEqual(results.count, 12)
            XCTAssertTrue(results.allSatisfy { $0 == [baseLogo] })
            let again = await catalog.sources(for: baseSource(contracts[0]))
            XCTAssertEqual(again, [baseLogo])
            let calls = await feed.calls
            XCTAssertEqual(calls, [basePrimary: 1, baseSecondary: 1])
        }
    }

    func testExistingProviderCooldownStillAllowsIndependentBaseRecovery() async throws {
        let ethereum = "https://tokens.coingecko.com/ethereum/all.json"
        let feed = BaseCatalogFeed([ethereum: .limited,
            baseSecondary: .bytes(try JSONSerialization.data(withJSONObject: baseRows([baseContract])))])
        let catalog = ArtworkFallbackCatalog(transport: feed)
        _ = await catalog.sources(for: baseSource().replacingOccurrences(of: "/base/", with: "/ethereum/"))
        let recovered = await catalog.sources(for: baseSource())
        XCTAssertEqual(recovered, [baseLogo])
        let calls = await feed.calls
        XCTAssertEqual(calls, [ethereum: 1, baseSecondary: 1], "Do not retry the cooling-down provider for Base")
    }

    func testHealthyPrimaryDoesNotRequestIndependentCatalog() async throws {
        let feed = BaseCatalogFeed([basePrimary: .bytes(try JSONSerialization.data(withJSONObject: ["tokens": baseRows([baseContract])]))])
        let catalog = ArtworkFallbackCatalog(transport: feed)
        let sources = await catalog.sources(for: baseSource())
        XCTAssertEqual(sources, [baseLogo])
        let calls = await feed.calls
        XCTAssertEqual(calls, [basePrimary: 1])
    }

    func testIndependentCatalogRejectsConflictsWrongChainAndUnsafeArtwork() async throws {
        for rows in [baseRows([baseContract]) + baseRows([baseContract], logo: "https://cdn.example.org/conflict.png"),
                     baseRows([baseContract], chain: 1),
                     baseRows([baseContract], logo: "https://localhost/private.png")] {
            let feed = BaseCatalogFeed([basePrimary: .limited,
                baseSecondary: .bytes(try JSONSerialization.data(withJSONObject: rows))])
            let catalog = ArtworkFallbackCatalog(transport: feed)
            for _ in 0..<3 {
                let sources = await catalog.sources(for: baseSource())
                XCTAssertTrue(sources.isEmpty)
            }
            let calls = await feed.calls
            XCTAssertEqual(calls, [basePrimary: 1, baseSecondary: 1])
        }
    }

    func testCancellationDoesNotStartFallbackOrPoisonNextRead() async throws {
        let feed = BaseCatalogFeed([basePrimary: .cancelled])
        let catalog = ArtworkFallbackCatalog(transport: feed)
        let cancelled = await catalog.sources(for: baseSource())
        XCTAssertTrue(cancelled.isEmpty)
        await feed.set(.bytes(try JSONSerialization.data(withJSONObject: ["tokens": baseRows([baseContract])])), for: basePrimary)
        let next = await catalog.sources(for: baseSource())
        XCTAssertEqual(next, [baseLogo])
        let calls = await feed.calls
        XCTAssertEqual(calls, [basePrimary: 2])
    }
}

private actor BasePublicArtwork: ArtworkTransport {
    private(set) var calls: [String: Int] = [:]
    let offline: Bool
    init(offline: Bool = false) { self.offline = offline }
    func data(from url: URL) async throws -> Data {
        calls[url.absoluteString, default: 0] += 1
        if offline { throw ArtworkError.http(503) }
        if url.host == "tokens.coingecko.com" { throw ArtworkRateLimit(retryAfter: "120") }
        return try await ArtworkURLTransport().data(from: url)
    }
}
private actor BaseNoPerTokenMetadata: TokenArtworkMetadata {
    private(set) var requests = 0
    func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] {
        if !cachedOnly { requests += 1 }; return []
    }
}

final class BaseArtworkLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testRealRegistryAndImagesRecoverFromPrimaryRateLimitAndPersistOffline() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_BASE_ARTWORK"] == "1" else {
            throw XCTSkip("Opt-in public Base registry and image reads, no wallet or credentials")
        }
        // Public Base deployments: USDC, bridged USDT and WETH.
        let contracts = [baseContract, "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", "0x4200000000000000000000000000000000000006"]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let feed = BasePublicArtwork(), metadata = BaseNoPerTokenMetadata()
        func resolver(_ feed: any ArtworkTransport) -> TokenArtworkResolver {
            TokenArtworkResolver(loader: ArtworkLoader(directory: directory.appendingPathComponent("images"),
                transport: feed, fallbackCatalog: ArtworkFallbackCatalog(transport: feed)),
                metadata: metadata, directory: directory.appendingPathComponent("identities"))
        }
        let live = resolver(feed)
        for contract in contracts {
            let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "base", reference: contract))
            let image = await live.image(for: token, sources: [baseSource(contract)])
            XCTAssertNotNil(image, "Public Base token artwork failed to decode: \(contract)")
        }
        let calls = await feed.calls
        XCTAssertEqual(calls[basePrimary], 1)
        XCTAssertEqual(calls[baseSecondary], 1)
        XCTAssertFalse(calls.keys.contains { $0.contains("/blockchains/base/assets/") })
        let perToken = await metadata.requests; XCTAssertEqual(perToken, 0)
        let offline = BasePublicArtwork(offline: true), relaunched = resolver(offline)
        for contract in contracts {
            let token = try XCTUnwrap(TokenArtworkIdentity(networkID: "base", reference: contract))
            let cached = await relaunched.image(for: token, sources: [])
            XCTAssertNotNil(cached)
        }
        let offlineCalls = await offline.calls; XCTAssertTrue(offlineCalls.isEmpty)
        print("BASE_ARTWORK_LIVE 3 exact contracts: decoded, shared catalog, no per-token metadata calls, offline relaunch")
    }
}
