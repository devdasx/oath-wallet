import XCTest
import OathDatabase
@testable import OathMarketData

/// Opt-in host tests: no simulator, wallet address, credential or balance RPC.
@MainActor final class MarketLiveTests: XCTestCase {
    func testNativeProviderCoverageAndKeylessInformationWithPersistentFallback() async throws {
        guard ProcessInfo.processInfo.environment["OATH_MARKET_LIVE"] == "1" else { throw XCTSkip("Opt-in public provider test") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oath-market-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        let definitions = MarketIdentity.native.sorted { $0.key < $1.key }
        try await db.seed(networks: definitions.enumerated().map { index, pair in
            .init(id: pair.key, name: pair.key, family: "fixture", symbol: pair.value.coinbase, decimals: 18, derivationPath: "fixture", logo: "", sortOrder: index)
        }, assets: definitions.map { pair in
            .init(id: pair.key + ":native", networkID: pair.key, reference: "native", name: pair.key, symbol: pair.value.coinbase, decimals: 18)
        })
        let service = MarketDataService(database: db)
        var checked = Set<String>()
        var quotes = 0
        for (network, mapping) in definitions {
            guard checked.insert(mapping.coinbase).inserted else { continue }
            let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: 18)
            do {
                let value = try await service.quote(for: asset)
                XCTAssertGreaterThan(try XCTUnwrap(value.value.decimal), .zero)
                XCTAssertEqual(value.value.code, mapping.coinbase)
                quotes += 1
                print("OATH_MARKET_LIVE_QUOTE \(network) \(mapping.coinbase) validated")
            } catch {
                // These three identities have no Coinbase USD spot listing.
                // Never silently substitute GNO for xDAI, or a matching ticker.
                guard ["XDAI", "TLOS", "OKB"].contains(mapping.coinbase), error as? MarketDataError == .notListed else { throw error }
                print("OATH_MARKET_LIVE_NOT_LISTED \(network) \(mapping.coinbase)")
            }
        }
        XCTAssertGreaterThanOrEqual(checked.count, 20)
        XCTAssertGreaterThanOrEqual(quotes, 17)
        let eth = MarketAsset(id: "ethereum:native", networkID: "ethereum", reference: "native", decimals: 18)
        _ = try await service.quote(for: eth)
        print("OATH_MARKET_LIVE_METADATA ethereum starting")
        let nativeInfo = try await service.information(for: eth)
        XCTAssertEqual(nativeInfo.value.providerID, "ethereum")
        XCTAssertFalse(nativeInfo.value.description.isEmpty)
        let chart = try await service.chart(for: eth)
        XCTAssertGreaterThanOrEqual(chart.value.points.count, 20)
        for (network, reference) in [
            ("ethereum", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
            ("tron", "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"),
            ("solana", "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v")
        ] {
            // Public keyless metadata quotas are shared by IP. Keep this opt-in
            // provider check deliberately slower than the isolated unit tests.
            try await Task.sleep(for: .seconds(12))
            let id = network + ":" + reference
            try await db.saveAsset(.init(id: id, networkID: network, reference: reference, name: "Public fixture", symbol: "fixture", decimals: 6))
            let token = MarketAsset(id: id, networkID: network, reference: reference, decimals: 6)
            print("OATH_MARKET_LIVE_METADATA \(network) token starting")
            let information = try await service.information(for: token)
            let price = try await service.quote(for: token)
            XCTAssertTrue(["usd-coin", "tether"].contains(information.value.providerID))
            XCTAssertGreaterThan(try XCTUnwrap(price.value.decimal), 0)
            print("OATH_MARKET_LIVE_TOKEN \(network) identity, metadata, contract quote validated")
        }
        let reopened = try await OathDatabase.open(at: url)
        let offline = MarketDataService(database: reopened, transport: Offline(), now: { Date().addingTimeInterval(172_800) })
        let retained = try await offline.quote(for: eth)
        XCTAssertFalse(retained.isFresh(at:Date().addingTimeInterval(172_800),lifetime:60))
        let saved = try await offline.cachedQuote(for: eth)
        let savedInfo = try await offline.cachedInformation(for: eth)
        let savedChart = try await offline.cachedChart(for: eth)
        XCTAssertNotNil(saved); XCTAssertEqual(savedInfo?.value, nativeInfo.value); XCTAssertEqual(savedChart?.value, chart.value)
        print("OATH_MARKET_LIVE_REOPEN_OFFLINE_FALLBACK validated")
    }
}
private struct Offline: MarketTransport {
    func data(from url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
}
