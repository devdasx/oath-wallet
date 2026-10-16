import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class WalletResetTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathReset-" + UUID().uuidString)
            .appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "bitcoin", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8,
            derivationPath: "fixture", logo: "btc", sortOrder: 0)],
            assets: [.init(id: "btc", networkID: "bitcoin", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8)])
        for id in ["one", "two"] {
            try await db.importWalletIfNeeded(.init(id: id, name: id, kind: "hd", vaultReference: id, createdAt: 1),
                accounts: [.init(id: id, walletID: id, networkID: "bitcoin", address: "fixture-" + id, derivationPath: "fixture")])
        }
        try await db.setSetting("activeWalletID", value: "one")
        for (key, value) in ["currency": "USD", "language": "ar", "appearance": "dark", "appIcon": "dark",
                              "security.lockDelay": "300", "security.appSwitcherPrivacy": "true", "balancesHidden": "true"] {
            try await db.setSetting(key, value: value)
        }
        try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "123.45", observedAt: 10, source: "fixture")])
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "JOD": "0.709"], observedAt: 10, fetchedAt: 11, source: "fixture"))
        try await db.pool.write { sql in
            try sql.execute(sql: """
                INSERT INTO balances VALUES('one','btc','bitcoin','1',1,NULL,'fixture');
                INSERT INTO transactions VALUES('t','bitcoin','fixture-hash','confirmed',1,NULL,1,NULL,1);
                INSERT INTO transfers VALUES('t:0','t','bitcoin','btc',0,'fixture-from','fixture-to','1');
                INSERT INTO activity(id,walletID,accountID,networkID,transactionID,assetID,direction,amountAtomic,counterparty,timestamp)
                    VALUES('a','one','one','bitcoin','t','btc','incoming','1','fixture',1);
                INSERT INTO sends(id,walletID,accountID,networkID,assetID,senderAddress,idempotencyKey,recipient,
                    amountAtomic,state,signedPayload,transactionID,createdAt,updatedAt)
                    VALUES('s','one','one','bitcoin','btc','fixture','fixture','fixture','1','signed',X'001122','t',1,1);
                INSERT INTO utxos VALUES('bitcoin','fixture',0,5,'fixture',1,0,'s',1);
                INSERT INTO accountUTXOs VALUES('one','bitcoin','fixture',0);
                INSERT INTO receives VALUES('r','one','bitcoin','btc','fixture',NULL,NULL,'open',1,NULL);
                INSERT INTO notes VALUES('n','one','transaction','t','SYNTHETIC-RESET-NOTE',1);
                INSERT INTO labels VALUES('l','one','fixture-label','red',1);
                INSERT INTO labelAssignments VALUES('l','one','transaction','t');
                INSERT INTO syncCursors VALUES('one','history','fixture',1,NULL,1);
                INSERT INTO cloudBackups VALUES('one','b','fixture-cloud',1,'queued',X'001122',1,NULL,0,NULL);
                INSERT INTO contacts VALUES('c','SYNTHETIC-RESET-CONTACT','fixture',1,1,1);
                INSERT INTO contactAddresses VALUES('ca','c','bitcoin','fixture','fixture','fixture',0);
                INSERT INTO metadata VALUES('legacySettingsMigrated','true');
                """)
        }
        return (db, url)
    }

    func testFullLedgerErasurePreservesSettingsPricesAndRates() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var preferences = try await db.settings()
        preferences.removeValue(forKey: "activeWalletID")
        let rates = try await db.exchangeRates()
        let id = try await db.beginWalletReset()
        try await db.eraseWalletData(resetID: id)
        let counts = try await db.pool.read { sql in
            try OathDatabase.walletDataTables.map { try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM \($0)")! }
        }
        XCTAssertTrue(counts.allSatisfy { $0 == 0 }, "Every wallet table must be empty, including shared ledger rows")
        let settingsAfter = try await db.settings(), ratesAfter = try await db.exchangeRates()
        XCTAssertEqual(settingsAfter, preferences); XCTAssertEqual(ratesAfter, rates)
        let quote = try await db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM prices WHERE assetID='btc'") }
        XCTAssertEqual(quote, "123.45")
        let searchCount = try await db.pool.read { sql in
            try Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM notesSearch WHERE notesSearch MATCH 'SYNTHETIC'")!
                + Int.fetchOne(sql, sql: "SELECT COUNT(*) FROM contactsSearch WHERE contactsSearch MATCH 'SYNTHETIC'")!
        }
        XCTAssertEqual(searchCount, 0)
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("SYNTHETIC-RESET-NOTE".utf8)))
        XCTAssertNil(bytes.range(of: Data("SYNTHETIC-RESET-CONTACT".utf8)))
        try await db.finishWalletReset(resetID: id)
        let pending = try await db.pendingWalletReset()
        XCTAssertNil(pending)
        let legacyMarker = try await db.pool.read { try String.fetchOne($0, sql: "SELECT value FROM metadata WHERE key='legacySettingsMigrated'") }
        XCTAssertEqual(legacyMarker, "true", "Reset must not reimport retired settings or data")
        try await db.importWalletIfNeeded(.init(id: "new", name: "New", kind: "hd", vaultReference: "new", createdAt: 20), accounts: [])
        let wallets = try await db.wallets()
        XCTAssertEqual(wallets.map(\.id), ["new"])
    }

    func testDurableIntentBlocksWritersAndSurvivesReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = try await db.beginWalletReset()
        let reopened = try await OathDatabase.open(at: url)
        let sameID = try await reopened.beginWalletReset()
        XCTAssertEqual(sameID, id)
        do {
            try await reopened.importWalletIfNeeded(.init(id: "late", name: "late", kind: "hd", vaultReference: "late", createdAt: 1), accounts: [])
            XCTFail("Late wallet import must be blocked")
        } catch { }
        do { try await reopened.renameWallet("one", name: "late"); XCTFail("Update must be blocked") } catch { }
        do {
            _ = try await reopened.saveContact(id: UUID().uuidString, name: "late",
                addresses: [.init(networkID: "bitcoin", address: "fixture")], expectedRevision: nil)
            XCTFail("Late contact must be blocked")
        } catch { }
        do { try await reopened.finishWalletReset(resetID: id); XCTFail("Cannot finish before erasure") } catch { }
        do { try await reopened.eraseWalletData(resetID: "wrong"); XCTFail("Reject incorrect journal identity") } catch { }
        try await reopened.eraseWalletData(resetID: id)
        try await reopened.eraseWalletData(resetID: id) // A crash can repeat any step.
        try await reopened.finishWalletReset(resetID: id)
        let pending = try await reopened.pendingWalletReset()
        XCTAssertNil(pending)
    }

    func testFailureRollsBackLedgerButKeepsResetIntentForRetry() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = try await db.beginWalletReset()
        try await db.pool.write { try $0.execute(sql: "CREATE TRIGGER fixtureFailure BEFORE DELETE ON contacts BEGIN SELECT RAISE(ABORT,'fixture failure'); END") }
        do { try await db.eraseWalletData(resetID: id); XCTFail("Injected erasure failure must be reported") } catch { }
        let pending = try await db.pendingWalletReset(), wallets = try await db.wallets()
        XCTAssertEqual(pending, id); XCTAssertEqual(wallets.count, 2)
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER fixtureFailure") }
        try await db.eraseWalletData(resetID: id)
        try await db.finishWalletReset(resetID: id)
    }
}
