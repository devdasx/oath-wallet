import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

final class RateLimitRecoveryTests: XCTestCase, @unchecked Sendable {
    func testNarrowFallbackPreservesVerifiedCatalogAndRejectsPrecisionConflict() throws {
        let first = "0x" + String(repeating: "a", count: 40), second = "0x" + String(repeating: "b", count: 40)
        let previous = VerifiedEVMTokenCatalog(networkID: "xlayer", decimalsByReference: [first: 6])
        let fallback = VerifiedEVMTokenCatalog(networkID: "xlayer", decimalsByReference: [second: 18], source: "OKX")
        XCTAssertEqual(try fallback.retainingVerifiedEntries(from: previous).decimalsByReference, [first: 6, second: 18])
        let conflict = VerifiedEVMTokenCatalog(networkID: "xlayer", decimalsByReference: [first: 18], source: "OKX")
        XCTAssertThrowsError(try conflict.retainingVerifiedEntries(from: previous))
    }
    func testStoryOfflineFloorContainsOnlyPreviouslyVerifiedContractsWithoutInventedDecimals() async throws {
        let value = try await VerifiedEVMTokenCatalog.fetch(chain: .story, transport: AlwaysRateLimited())
        XCTAssertEqual(value.networkID, "story")
        XCTAssertTrue(value.decimalsByReference.isEmpty)
        XCTAssertEqual(value.referencesWithoutDecimals?.count, 7)
        XCTAssertTrue(value.referencesWithoutDecimals?.allSatisfy(AnkrQuantity.address) == true)
        XCTAssertEqual(value.source, "CoinGecko verified snapshot 2026-10-17")
    }

    func testIssuerListFiltersTestnetAndRejectsConflictingMainnetPrecision() throws {
        let address = "0x" + String(repeating: "a", count: 40)
        let data = try JSONSerialization.data(withJSONObject: ["tokens": [
            ["chainId": 40, "address": address, "decimals": 18],
            ["chainId": 41, "address": address, "decimals": 6]]])
        XCTAssertThrowsError(try VerifiedEVMTokenCatalog.decode(data, chain: .telos))
        let catalog = try VerifiedEVMTokenCatalog.decode(data, chain: .telos, allowsOtherChains: true)
        XCTAssertEqual(catalog.decimalsByReference, [address: 18])
        let conflict = try JSONSerialization.data(withJSONObject: ["tokens": [
            ["chainId": 40, "address": address, "decimals": 18],
            ["chainId": 40, "address": address, "decimals": 6]]])
        XCTAssertThrowsError(try VerifiedEVMTokenCatalog.decode(conflict, chain: .telos, allowsOtherChains: true))
    }

    func testHTTPRateLimitSharesRujiraCooldownAcrossOperations() async throws {
        let cache = ThorchainCatalogRequests(), counter = RecoveryCounter()
        for attempt in 0..<10 {
            do {
                _ = try await cache.graphQL { _ = await counter.response(); throw ThorchainError.http(429) }
                XCTFail()
            } catch {
                if attempt == 0 { XCTAssertEqual(error as? ThorchainError, .http(429)) }
                else { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
            }
        }
        let count = await counter.count; XCTAssertEqual(count, 1)
    }
    func testCoinbaseCacheIsSharedAndAnonymousRoutesOnly() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = RecoveryCounter()
        let request = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/ETH-USD/spot")!)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await pool.send(request) { await counter.response() } } }
            try await group.waitForAll()
        }
        _ = try await pool.send(request) { await counter.response() }
        let count = await counter.count; XCTAssertEqual(count, 1)
        XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: "https://api.coinbase.com/v2/accounts")!)))
        XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: "https://raw.githubusercontent.com/someone/untrusted/main/tokens.json")!)))
    }

    func testEquivalentQueriesDoNotSpendProviderQuotaTwice() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = RecoveryCounter()
        for suffix in ["ids=monad,ethereum&vs_currencies=usd", "vs_currencies=usd&ids=ethereum,monad,monad"] {
            _ = try await pool.send(URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?" + suffix)!)) { await counter.response() }
        }
        let count = await counter.count; XCTAssertEqual(count, 1)
    }

    func testIndependentNativeFallbackRejectsStaleWrongIdentityAndLowConfidence() throws {
        let now = Date(timeIntervalSince1970: 2000)
        for key in ["coingecko:ethereum", "coingecko:monad", "coingecko:hyperliquid"] {
            for (time, confidence, accepted) in [(1900, "0.99", true), (100, "0.99", false), (3000, "0.99", false), (1900, "0.5", false)] {
                let json: SolanaJSON = .object(["coins": .object([key: .object(["price": .number("1.25"), "timestamp": .number(String(time)), "confidence": .number(confidence)])])])
                if accepted {
                    let value = try NativePriceFallback.decodeLlama(json, key: key, now: now)
                    XCTAssertEqual(value.usd, "1.25"); XCTAssertEqual(value.date.timeIntervalSince1970, 1900)
                } else { XCTAssertThrowsError(try NativePriceFallback.decodeLlama(json, key: key, now: now)) }
                XCTAssertThrowsError(try NativePriceFallback.decodeLlama(json, key: "coingecko:unrelated", now: now))
            }
        }
    }

    func testRESTVaultRatioIsConvertedExactlyOnce() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let config: SolanaJSON = .object(["denom": .string("rune")])
        let status: SolanaJSON = .object(["last_updated": .string("1990000000000"), "deposit_pool": .object(["ratio": .string("1.25"), "shares": .string("100")])])
        let row = try ThorchainClient.decodeNodeVault(config: config, status: status, now: now)
        var catalog = ThorchainCatalog()
        catalog.prices["native"] = "2"
        catalog.tokens["x/ghost-vault/rune"] = .init(reference: "x/ghost-vault/rune", name: "Fixture", symbol: "F", decimals: 8)
        try ThorchainClient.applyVaultMarkets([row], to: &catalog, now: now)
        XCTAssertEqual(catalog.prices["x/ghost-vault/rune"], "2.5")
        XCTAssertThrowsError(try ThorchainClient.decodeNodeVault(config: config, status: status, now: now.addingTimeInterval(4000)))
    }

    func testLiveNativeFallbacksWhilePrimaryProvidersAreLocallyDeferred() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RATE_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public quote reads") }
        for chain in ["hyperevm", "monad", "unichain"] {
            let transport = RecoveryLiveTransport(blockCoinbase: true, defersBlocked: true)
            let usd: String, source: String
            if chain == "hyperevm" {
                let value = try await HyperEVMMarkets(transport: transport).nativePrice()
                usd = value.usd; source = value.source
            } else {
                let value = try await IndexedEVMMarkets(chain: XCTUnwrap(IndexedEVMChain(rawValue: chain)), transport: transport).nativePrice()
                usd = value.usd; source = value.source
            }
            XCTAssertGreaterThan(try XCTUnwrap(Decimal(string: usd)), 0)
            XCTAssertEqual(source, "DefiLlama")
            print("LIVE_RECOVERY chain=\(chain) source=DefiLlama primaryAndSecondary=local_deferral")
        }
    }

    func testLiveAllAffectedNativeFallbacksWithCoinGeckoAndCoinbaseBlocked() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RATE_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public API reads") }
        for chain in ["hyperevm", "monad", "unichain"] {
            let transport = RecoveryLiveTransport(blockCoinbase: true)
            let usd: String, source: String
            if chain == "hyperevm" {
                let price = try await HyperEVMMarkets(transport: transport).nativePrice(); usd = price.usd; source = price.source
            } else {
                let price = try await IndexedEVMMarkets(chain: XCTUnwrap(IndexedEVMChain(rawValue: chain)), transport: transport).nativePrice(); usd = price.usd; source = price.source
            }
            XCTAssertGreaterThan(try XCTUnwrap(Decimal(string: usd)), 0)
            XCTAssertEqual(source, "DefiLlama")
            print("LIVE_RECOVERY chain=\(chain) source=DefiLlama primaryAndSecondary=429")
        }
    }

    func testLiveIssuerCatalogsWithBothCoinGeckoHostsBlocked() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RATE_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public API reads") }
        for chain: AnkrChain in [.telos, .xlayer] {
            let value = try await VerifiedEVMTokenCatalog.fetch(chain: chain, transport: RecoveryLiveTransport())
            XCTAssertFalse(value.decimalsByReference.isEmpty)
            XCTAssertEqual(value.networkID, chain.networkID)
            XCTAssertEqual(value.source, chain == .telos ? "Telos" : "OKX")
            print("LIVE_RECOVERY chain=\(chain.networkID) contracts=\(value.decimalsByReference.count) source=\(value.source!)")
        }
    }

    func testLiveThorchainCatalogSurvivesRujiraAndCoinGeckoRateLimits() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RATE_RECOVERY_LIVE"] == "1" else { throw XCTSkip("Opt-in public chain reads; no wallets or signing") }
        let transport = RecoveryLiveTransport()
        let client = ThorchainClient(transport: transport)
        async let first = client.catalog()
        async let second = client.catalog()
        let (catalog, duplicate) = try await (first, second)
        for ref in ["native", "x/ruji", "tcy"] {
            XCTAssertGreaterThan(Decimal(string: try XCTUnwrap(catalog.prices[ref])) ?? 0, 0, ref)
        }
        let receipts = catalog.prices.keys.filter { $0.hasPrefix("x/ghost-vault/") }
        XCTAssertGreaterThan(receipts.count, 10, "On-chain vault fallback must recover real receipt valuations")
        XCTAssertEqual(catalog.prices, duplicate.prices)
        _ = try await client.catalog()
        let rujiraCalls = await transport.rujiraCalls
        XCTAssertEqual(rujiraCalls, 1, "One shared cooldown covers oracle and vault; repeated refresh reuses catalog")
        print("LIVE_RECOVERY chain=thorchain prices=\(catalog.prices.count) vaults=\(receipts.count) rujiraCalls=\(rujiraCalls)")
    }
}

private actor RecoveryCounter {
    var count = 0
    func response() -> PublicMarketRequests.Response { count += 1; return .init(data: Data("fixture".utf8), status: 200) }
}

private struct AlwaysRateLimited: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 429) }
}

private actor RecoveryLiveTransport: AnkrTransport {
    let blockCoinbase: Bool
    let defersBlocked: Bool
    let base = AnkrHTTPTransport()
    private(set) var rujiraCalls = 0
    init(blockCoinbase: Bool = false, defersBlocked: Bool = false) {
        self.blockCoinbase = blockCoinbase; self.defersBlocked = defersBlocked
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = request.url?.host
        if host == "api.rujira.network" {
            rujiraCalls += 1
            return (Data(#"{"errors":[{"message":"rate bucket full (5000). bucket drains 500/s."}]}"#.utf8), 200)
        }
        if host == "api.coingecko.com" || host == "tokens.coingecko.com" || (blockCoinbase && host == "api.coinbase.com") {
            if defersBlocked { throw DiagnosticDeferral.publicMarketCooldown }
            return (Data(), 429)
        }
        return try await base.send(request)
    }
}
