import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class TrackedAssetTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathTokens-" + UUID().uuidString)
            .appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: ["ethereum", "base"].enumerated().map { index, id in
            .init(id: id, name: id, family: "evm", symbol: "ETH", decimals: 18,
                  derivationPath: "fixture", logo: id, sortOrder: index)
        }, assets: ["ethereum", "base"].map {
            .init(id: $0 + ":native", networkID: $0, reference: "native", name: $0, symbol: "ETH", decimals: 18)
        })
        for wallet in ["one", "two"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: wallet, kind: "hd", vaultReference: wallet, createdAt: 1),
                accounts: ["ethereum", "base"].map { .init(id: wallet + $0, walletID: wallet,
                    networkID: $0, address: "0x0000000000000000000000000000000000000001", derivationPath: "fixture") })
        }
        return (db, url)
    }

    private func token(_ network: String = "ethereum", decimals: Int = 6, uppercase: Bool = false) -> AssetRecord {
        let address = "0xabcdef0000000000000000000000000000000001"
        return .init(id: network + ":fixture", networkID: network,
            reference: uppercase ? address.uppercased() : address, name: "Fixture Coin", symbol: "FXT", decimals: decimals,
            logo: "https://example.invalid/logo.png")
    }

    func testAddedTokenPersistsWithoutInventingBalanceAndStaysWalletScoped() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        let reopened = try await OathDatabase.open(at: url)
        let first = try await reopened.snapshot(walletID: "one", currency: "USD")
        let second = try await reopened.snapshot(walletID: "two", currency: "USD")
        let holding = try XCTUnwrap(first.holdings.first { $0.assetID == "ethereum:fixture" })
        XCTAssertEqual(holding.name, "Fixture Coin"); XCTAssertEqual(holding.symbol, "FXT")
        XCTAssertEqual(holding.decimals, 6); XCTAssertEqual(holding.reference, token().reference)
        XCTAssertEqual(holding.logo, token().logo)
        XCTAssertNil(holding.amountAtomic); XCTAssertNil(holding.balanceObservedAt)
        XCTAssertFalse(second.holdings.contains { $0.assetID == holding.assetID })
        let stored = try await reopened.balance(accountID: "oneethereum", assetID: holding.assetID)
        XCTAssertNil(stored)
    }

    func testDuplicateAddsCaseVariantsAndFetchedBalancesDoNotDuplicateRows() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        var repeated = token(uppercase: true); repeated.id = "different-input-id"
        let existing = try await db.trackAsset(repeated, walletID: "one")
        XCTAssertEqual(existing.id, "ethereum:fixture")
        try await db.saveBalances([.init(accountID: "oneethereum", assetID: existing.id, networkID: "ethereum",
            amountAtomic: "123456789", observedAt: 2, source: "fixture")])
        let snapshot = try await db.snapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(snapshot.holdings.filter { $0.assetID == existing.id }.count, 1)
        XCTAssertEqual(snapshot.holdings.first { $0.assetID == existing.id }?.amountAtomic, "123456789")
        // The same address on another network is a separate asset identity.
        try await db.trackAsset(token("base", decimals: 18), walletID: "one")
        let tracked = try await db.trackedAssets(walletID: "one")
        XCTAssertEqual(tracked.count, 2)
        XCTAssertEqual(Set(tracked.map(\.networkID)), ["ethereum", "base"])
    }

    func testConflictingDecimalsAndMissingWalletCannotPartiallyChangeAsset() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        var conflicting = token(decimals: 18); conflicting.name = "Incorrect Replacement"
        do { try await db.trackAsset(conflicting, walletID: "two"); XCTFail("Changed token decimals") }
        catch { XCTAssertEqual(error as? StoreError, .conflictingIdentity) }
        do { try await db.trackAsset(token("base"), walletID: "missing"); XCTFail("Accepted missing wallet") }
        catch { XCTAssertEqual(error as? StoreError, .missingRecord) }
        let first = try await db.trackedAssets(walletID: "one"), second = try await db.trackedAssets(walletID: "two")
        XCTAssertEqual(first.first?.name, "Fixture Coin"); XCTAssertEqual(first.first?.decimals, 6)
        XCTAssertTrue(second.isEmpty)
    }

    func testResetFencesTokenTrackingAndErasesSelectionWhilePreservingPrices() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.setSetting("currency", value: "JOD")
        try await db.savePrices([.init(assetID: "ethereum:fixture", currency: "USD", value: "1.25", observedAt: 1, source: "fixture")])
        let reset = try await db.beginWalletReset()
        do { try await db.trackAsset(token("base"), walletID: "two"); XCTFail("Tracked during reset") } catch { }
        let rolledBack = try await db.pool.read { try AssetRecord.fetchOne($0, key: "base:fixture") }
        XCTAssertNil(rolledBack)
        try await db.eraseWalletData(resetID: reset)
        try await db.finishWalletReset(resetID: reset)
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM trackedAssets") }
        let price = try await db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM prices WHERE assetID='ethereum:fixture'") }
        let settings = try await db.settings()
        XCTAssertEqual(count, 0); XCTAssertEqual(price, "1.25"); XCTAssertEqual(settings["currency"], "JOD")
    }

    func testUpgradeFromPreviousSchemaPreservesExistingWalletAndLedger() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.saveBalances([.init(accountID: "oneethereum", assetID: "ethereum:native", networkID: "ethereum",
            amountAtomic: "1234567890123456789", observedAt: 5, source: "fixture")])
        // Recreate the immediately preceding schema in this isolated database.
        try await db.pool.write {
            try $0.execute(sql: "DROP TABLE trackedAssets; DELETE FROM grdb_migrations WHERE identifier='v8_tracked_tokens';")
        }
        let upgraded = try await OathDatabase.open(at: url)
        try await upgraded.trackAsset(token(), walletID: "one")
        let wallet = try await upgraded.snapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(wallet.wallet.name, "one")
        XCTAssertEqual(wallet.holdings.first { $0.assetID == "ethereum:native" }?.amountAtomic, "1234567890123456789")
        XCTAssertTrue(wallet.holdings.contains { $0.assetID == "ethereum:fixture" })
    }
}
