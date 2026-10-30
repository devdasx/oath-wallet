import XCTest
import OathDatabase
@testable import OathMarketData

@MainActor final class RateLimitedNativePriceTests: XCTestCase {
    func testValidOlderObservationDoesNotRefetchOrAcquireAFakeTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        try await db.seed(networks: [.init(id: "bitcoin", name: "Bitcoin", family: "fixture", symbol: "BTC", decimals: 8, derivationPath: "fixture", logo: "", sortOrder: 0)],
            assets: [.init(id: "bitcoin:native", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8)])
        let now = Date(timeIntervalSince1970: 2000)
        let transport = OlderQuoteTransport()
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let asset = MarketAsset(id: "bitcoin:native", networkID: "bitcoin", reference: "native", decimals: 8)
        let first = try await service.quote(for: asset)
        XCTAssertEqual(first.fetchedAt.timeIntervalSince1970, 1800)
        let before = await transport.count
        for _ in 0..<20 {
            let next = try await service.quote(for: asset)
            XCTAssertEqual(next.fetchedAt, first.fetchedAt)
        }
        let after = await transport.count; XCTAssertEqual(after, before)
        let stored = try await db.latestPrice(assetID: asset.id, currency: "USD")
        XCTAssertEqual(stored?.observedAt, 1800)
    }
    func testLiveQuotesPersistWithCoinGeckoBlockedForEveryAffectedNativeNetwork() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RATE_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in anonymous public quotes") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rate-recovery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("fixture.sqlite"))
        let networks = ["bitcoin", "bitcoincash", "litecoin", "dogecoin", "thorchain", "hyperevm", "monad", "unichain"]
        let decimals = Dictionary(uniqueKeysWithValues: networks.map { ($0, ["hyperevm", "monad", "unichain"].contains($0) ? 18 : 8) })
        try await db.seed(networks: networks.enumerated().map { index, chain in
            NetworkRecord(id: chain, name: chain, family: "fixture", symbol: MarketIdentity.native[chain]!.coinbase,
                decimals: decimals[chain]!, derivationPath: "fixture", logo: "", sortOrder: index)
        }, assets: networks.map { chain in
            AssetRecord(id: chain + ":native", networkID: chain, reference: "native", name: chain,
                symbol: MarketIdentity.native[chain]!.coinbase, decimals: decimals[chain]!)
        })
        let transport = BlockedGeckoLiveTransport()
        let service = MarketDataService(database: db, transport: transport)
        for chain in networks {
            let asset = MarketAsset(id: chain + ":native", networkID: chain, reference: "native", decimals: decimals[chain]!)
            async let a = service.quote(for: asset)
            async let b = service.quote(for: asset)
            let (first, second) = try await (a, b)
            XCTAssertEqual(first.value.usd, second.value.usd)
            XCTAssertEqual(first.fetchedAt, second.fetchedAt)
            XCTAssertGreaterThan(first.value.decimal ?? 0, 0)
            let saved = try await db.latestPrice(assetID: asset.id, currency: "USD")
            let stored = try XCTUnwrap(saved)
            XCTAssertEqual(stored.value, first.value.usd)
            XCTAssertNotEqual(stored.source, "CoinGecko")
            let before = await transport.count
            _ = try await service.quote(for: asset)
            let after = await transport.count
            XCTAssertEqual(before, after, "Repeated reads must reuse the fresh quote")
            XCTAssertLessThan(Date().timeIntervalSince(first.fetchedAt), 900)
            print("LIVE_RECOVERY chain=\(chain) quoteSource=\(stored.source) persisted=true")
        }
    }
}

private actor OlderQuoteTransport: MarketTransport {
    private(set) var count = 0
    func data(from url: URL) async throws -> Data {
        count += 1
        guard url.host == "coins.llama.fi" else { throw MarketDataError.rateLimited }
        return Data(#"{"coins":{"coingecko:bitcoin":{"price":100,"timestamp":1800,"confidence":0.99}}}"#.utf8)
    }
}

private actor BlockedGeckoLiveTransport: MarketTransport {
    let base = URLSessionMarketTransport()
    private(set) var count = 0
    func data(from url: URL) async throws -> Data {
        count += 1
        if url.host == "api.coingecko.com" { throw MarketDataError.rateLimited }
        return try await base.data(from: url)
    }
}
