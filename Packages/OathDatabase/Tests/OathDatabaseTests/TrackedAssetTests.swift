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

    func testAddedTokenPersistsOnlyInSelectedWalletWithoutInventingBalance() async throws {
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
        // Even wallets with the same public address keep independent selections.
        XCTAssertFalse(second.holdings.contains { $0.assetID == holding.assetID })
        let otherTracked = try await reopened.trackedAssets(walletID: "two")
        XCTAssertTrue(otherTracked.isEmpty)
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

    func testLongMoveIdentityPersistsAndOversizedReferenceIsRejected() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.seed(networks: [.init(id: "sui", name: "Sui", family: "move", symbol: "SUI",
            decimals: 9, derivationPath: "fixture", logo: "sui", sortOrder: 2)], assets: [])
        try await db.importWalletIfNeeded(.init(id: "move", name: "move", kind: "hd", vaultReference: "move", createdAt: 1),
            accounts: [.init(id: "movesui", walletID: "move", networkID: "sui", address: "0x1", derivationPath: "fixture")])
        let ref = "0x" + String(repeating: "1", count: 64) + "::vault::Share<0x" + String(repeating: "2", count: 64) + "::coin::USDC>"
        XCTAssertGreaterThan(ref.count, 128)
        let asset = AssetRecord(id: "sui:" + ref, networkID: "sui", reference: ref, name: "Share", symbol: "SHARE", decimals: 6)
        try await db.trackAsset(asset, walletID: "move")
        let reopened = try await OathDatabase.open(at: url)
        let tracked = try await reopened.trackedAssets(walletID: "move")
        XCTAssertEqual(tracked.map(\.reference), [ref])
        var invalid = asset; invalid.reference = String(repeating: "x", count: 4097)
        do { try await db.trackAsset(invalid, walletID: "move"); XCTFail("Unbounded reference accepted") }
        catch { XCTAssertEqual(error as? StoreError, .invalidValue("token")) }
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
        // Recreate the schema before tracked tokens/visibility in this isolated database.
        try await db.pool.write {
            try $0.execute(sql: """
                DROP TABLE hiddenAssets;
                DELETE FROM grdb_migrations WHERE identifier IN
                    ('v66_asset_visibility_and_shared_tracking','v67_wallet_scoped_token_tracking');
                DROP TABLE trackedAssets; DELETE FROM grdb_migrations WHERE identifier='v8_tracked_tokens';
                """)
        }
        let upgraded = try await OathDatabase.open(at: url)
        try await upgraded.trackAsset(token(), walletID: "one")
        let wallet = try await upgraded.snapshot(walletID: "one", currency: "USD")
        XCTAssertEqual(wallet.wallet.name, "one")
        XCTAssertEqual(wallet.holdings.first { $0.assetID == "ethereum:native" }?.amountAtomic, "1234567890123456789")
        XCTAssertTrue(wallet.holdings.contains { $0.assetID == "ethereum:fixture" })
    }
    func testVisibilityIsWalletScopedDurableAndDoesNotChangeValuation() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.saveBalances([.init(accountID: "oneethereum", assetID: "ethereum:fixture", networkID: "ethereum",
            amountAtomic: "1234567", observedAt: 1, source: "fixture")])
        try await db.savePrices([.init(assetID: "ethereum:fixture", currency: "USD", value: "1", observedAt: 1, source: "fixture")])
        let before = try await db.snapshot(walletID: "one", currency: "USD")
        for asset in ["ethereum:native", "ethereum:fixture"] {
            try await db.setAssetHidden(true, assetID: asset, walletID: "one")
            try await db.setAssetHidden(true, assetID: asset, walletID: "one") // Idempotent swipe.
        }
        // Re-adding from another wallet never resets this wallet's hide choice.
        try await db.trackAsset(token(), walletID: "two")
        let reopened = try await OathDatabase.open(at: url)
        let first = try await reopened.snapshot(walletID: "one", currency: "USD")
        let second = try await reopened.snapshot(walletID: "two", currency: "USD")
        XCTAssertEqual(first.hiddenAssetIDs, ["ethereum:native", "ethereum:fixture"])
        XCTAssertTrue(second.hiddenAssetIDs.isEmpty)
        XCTAssertEqual(first.totalFiat, before.totalFiat)
        XCTAssertEqual(first.holdings, before.holdings)
        var observer = reopened.observeHiddenAssets(walletID: "one").makeAsyncIterator()
        let hidden = try await observer.next()
        XCTAssertEqual(Set(hidden?.map(\.id) ?? []), first.hiddenAssetIDs)
        try await reopened.setAssetHidden(false, assetID: "ethereum:fixture", walletID: "one")
        let next = try await observer.next()
        XCTAssertEqual(next?.map(\.id), ["ethereum:native"])
        try await reopened.setAssetHidden(false, assetID: "ethereum:native", walletID: "one")
        let shown = try await reopened.snapshot(walletID: "one", currency: "USD")
        XCTAssertTrue(shown.hiddenAssetIDs.isEmpty)
    }

    func testLaterWalletAndAccountsDoNotInheritAnotherWalletsSelections() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.importWalletIfNeeded(.init(id: "later", name: "Later", kind: "privateKey", vaultReference: "later", createdAt: 2),
            accounts: [.init(id: "later-base", walletID: "later", networkID: "base", address: "fixture", derivationPath: "fixture")])
        let unsupported = try await db.trackedAssets(walletID: "later")
        XCTAssertTrue(unsupported.isEmpty)
        try await db.importWalletIfNeeded(.init(id: "later", name: "Later", kind: "privateKey", vaultReference: "later", createdAt: 2),
            accounts: [.init(id: "later-eth", walletID: "later", networkID: "ethereum", address: "other-fixture", derivationPath: "fixture")])
        let supported = try await db.trackedAssets(walletID: "later")
        XCTAssertTrue(supported.isEmpty)
        let beforeSelection = try await db.snapshot(walletID: "later", currency: "USD")
        XCTAssertFalse(beforeSelection.holdings.contains { $0.assetID == "ethereum:fixture" })
        try await db.trackAsset(token(), walletID: "later")
        let snapshot = try await db.snapshot(walletID: "later", currency: "USD")
        XCTAssertNil(snapshot.holdings.first { $0.assetID == "ethereum:fixture" }?.amountAtomic)
        XCTAssertEqual(snapshot.holdings.first { $0.assetID == "ethereum:fixture" }?.address, "other-fixture")
    }

    func testHidingAndRestoringInEitherWalletDoesNotChangeTheOtherWallet() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for wallet in ["one", "two"] {
            try await db.trackAsset(token(), walletID: wallet)
        }
        try await db.setAssetHidden(true, assetID: "ethereum:fixture", walletID: "two")
        let visibleFirst = try await db.snapshot(walletID: "one", currency: "USD")
        XCTAssertTrue(visibleFirst.hiddenAssetIDs.isEmpty)
        try await db.setAssetHidden(true, assetID: "ethereum:fixture", walletID: "one")
        try await db.setAssetHidden(false, assetID: "ethereum:fixture", walletID: "one")
        let reopened = try await OathDatabase.open(at: url)
        let first = try await reopened.snapshot(walletID: "one", currency: "USD")
        let second = try await reopened.snapshot(walletID: "two", currency: "USD")
        XCTAssertTrue(first.hiddenAssetIDs.isEmpty)
        XCTAssertEqual(second.hiddenAssetIDs, ["ethereum:fixture"])
        XCTAssertTrue(first.holdings.contains { $0.assetID == "ethereum:fixture" })
        XCTAssertTrue(second.holdings.contains { $0.assetID == "ethereum:fixture" })
    }

    func testResetFencesVisibilityAndClearsWalletPreferences() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.setAssetHidden(true, assetID: "ethereum:fixture", walletID: "one")
        let reset = try await db.beginWalletReset()
        for hidden in [true, false] {
            do { try await db.setAssetHidden(hidden, assetID: "ethereum:fixture", walletID: "one"); XCTFail("Changed visibility during reset") }
            catch { XCTAssertEqual(error as? StoreError, .missingRecord) }
        }
        try await db.eraseWalletData(resetID: reset)
        try await db.finishWalletReset(resetID: reset)
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM trackedAssets)+(SELECT COUNT(*) FROM hiddenAssets)") }
        XCTAssertEqual(count, 0)
    }

    func testPreviousWalletScopedSelectionsStayScopedAcrossVisibilityMigration() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.pool.write { db in
            try db.execute(sql: """
                DROP TABLE hiddenAssets;
                DELETE FROM grdb_migrations WHERE identifier IN
                    ('v66_asset_visibility_and_shared_tracking','v67_wallet_scoped_token_tracking');
                """)
        }
        let upgraded = try await OathDatabase.open(at: url)
        let first = try await upgraded.trackedAssets(walletID: "one")
        let second = try await upgraded.trackedAssets(walletID: "two")
        XCTAssertEqual(first.map(\.id), ["ethereum:fixture"])
        XCTAssertTrue(second.isEmpty)
    }

    func testSharedTrackingUpgradePreservesExistingListsAndStopsFutureSharing() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for wallet in ["one", "two"] {
            try await db.trackAsset(token(), walletID: wallet)
        }
        try await db.setAssetHidden(true, assetID: "ethereum:fixture", walletID: "one")
        try await db.saveBalances([.init(accountID: "oneethereum", assetID: "ethereum:fixture",
            networkID: "ethereum", amountAtomic: "1234567", observedAt: 1, source: "fixture")])
        let beforeFirst = try await db.snapshot(walletID: "one", currency: "USD")
        let beforeSecond = try await db.snapshot(walletID: "two", currency: "USD")
        try await restoreLegacySharedTracking(db)

        let upgraded = try await OathDatabase.open(at: url)
        let first = try await upgraded.snapshot(walletID: "one", currency: "USD")
        let second = try await upgraded.snapshot(walletID: "two", currency: "USD")
        XCTAssertEqual(first.holdings, beforeFirst.holdings)
        XCTAssertEqual(second.holdings, beforeSecond.holdings)
        XCTAssertEqual(first.hiddenAssetIDs, beforeFirst.hiddenAssetIDs)
        XCTAssertEqual(second.hiddenAssetIDs, beforeSecond.hiddenAssetIDs)
        try await upgraded.trackAsset(token("base"), walletID: "one")
        let secondTracked = try await upgraded.trackedAssets(walletID: "two")
        XCTAssertEqual(secondTracked.map(\.id), ["ethereum:fixture"])
        try await upgraded.importWalletIfNeeded(.init(id: "later", name: "Later", kind: "hd", vaultReference: "later", createdAt: 2),
            accounts: [.init(id: "later-eth", walletID: "later", networkID: "ethereum", address: "fixture", derivationPath: "fixture")])
        let laterTracked = try await upgraded.trackedAssets(walletID: "later")
        XCTAssertTrue(laterTracked.isEmpty)
    }

    func testRestoringADiscoveredTokenKeepsItVisibleWithoutGlobalAddition() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.seed(networks: [], assets: [token()])
        try await db.saveBalances([.init(accountID: "oneethereum", assetID: "ethereum:fixture", networkID: "ethereum",
            amountAtomic: "100", observedAt: 1, source: "fixture")])
        try await db.setAssetHidden(true, assetID: "ethereum:fixture", walletID: "one")
        try await db.pool.write { try $0.execute(sql: "DELETE FROM balances WHERE assetID='ethereum:fixture'") }
        var observer = db.observeHiddenAssets(walletID: "one").makeAsyncIterator()
        let hidden = try await observer.next()
        XCTAssertEqual(hidden?.map(\.id), ["ethereum:fixture"])
        try await db.setAssetHidden(false, assetID: "ethereum:fixture", walletID: "one")
        let shown = try await db.snapshot(walletID: "one", currency: "USD")
        XCTAssertTrue(shown.hiddenAssetIDs.isEmpty)
        XCTAssertTrue(shown.holdings.contains { $0.assetID == "ethereum:fixture" })
        XCTAssertNil(shown.holdings.first { $0.assetID == "ethereum:fixture" }?.amountAtomic)
        let other = try await db.trackedAssets(walletID: "two")
        XCTAssertTrue(other.isEmpty)
        do { try await db.setAssetHidden(true, assetID: "missing", walletID: "one"); XCTFail("Unknown asset accepted") }
        catch { XCTAssertEqual(error as? StoreError, .missingRecord) }
    }

    func testMigrationWithPendingResetDoesNotResurrectSelections() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.pool.write { db in
            try db.execute(sql: """
                DROP TABLE hiddenAssets;
                DELETE FROM grdb_migrations WHERE identifier IN
                    ('v66_asset_visibility_and_shared_tracking','v67_wallet_scoped_token_tracking');
                """)
        }
        let reset = try await db.beginWalletReset()
        let upgraded = try await OathDatabase.open(at: url)
        try await upgraded.eraseWalletData(resetID: reset)
        try await upgraded.finishWalletReset(resetID: reset)
        let count = try await upgraded.pool.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM trackedAssets)+(SELECT COUNT(*) FROM hiddenAssets)") }
        XCTAssertEqual(count, 0)
    }

    func testSharedTrackingUpgradeDuringPendingResetDoesNotResurrectSelections() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.trackAsset(token(), walletID: "one")
        try await db.setAssetHidden(true, assetID: "ethereum:fixture", walletID: "one")
        try await restoreLegacySharedTracking(db)
        let reset = try await db.beginWalletReset()
        let upgraded = try await OathDatabase.open(at: url)
        let pendingReset = try await upgraded.pendingWalletReset()
        XCTAssertEqual(pendingReset, reset)
        try await upgraded.eraseWalletData(resetID: reset)
        try await upgraded.finishWalletReset(resetID: reset)
        let count = try await upgraded.pool.read { try Int.fetchOne($0, sql: "SELECT (SELECT COUNT(*) FROM trackedAssets)+(SELECT COUNT(*) FROM hiddenAssets)") }
        XCTAssertEqual(count, 0)
    }

    private func restoreLegacySharedTracking(_ database: OathDatabase) async throws {
        // Reproduce the shipped v66 shared table and import trigger, including
        // persisted global selections. The v67 migration must handle this state.
        try await database.pool.write { db in
            try db.execute(sql: """
                DELETE FROM grdb_migrations WHERE identifier='v67_wallet_scoped_token_tracking';
                CREATE TABLE sharedTrackedAssets (
                    assetID TEXT PRIMARY KEY NOT NULL,
                    networkID TEXT NOT NULL, addedAt DOUBLE NOT NULL,
                    FOREIGN KEY(assetID,networkID) REFERENCES assets(id,networkID) ON DELETE CASCADE
                );
                INSERT INTO sharedTrackedAssets(assetID,networkID,addedAt)
                    SELECT assetID,networkID,MIN(addedAt) FROM trackedAssets GROUP BY assetID,networkID;
                CREATE TRIGGER track_shared_assets_on_account_insert AFTER INSERT ON accounts
                BEGIN
                    INSERT OR IGNORE INTO trackedAssets(accountID,assetID,networkID,addedAt)
                        SELECT NEW.id,assetID,networkID,addedAt FROM sharedTrackedAssets WHERE networkID=NEW.networkID;
                END;
                """)
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_sharedTrackedAssets_\(operation) BEFORE \(operation) ON sharedTrackedAssets
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
    }

}
