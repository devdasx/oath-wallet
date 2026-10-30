import Foundation
import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class HomeReadIndexTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("home-index-" + UUID().uuidString)
        let store = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        try await store.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH",
            decimals: 18, derivationPath: "", logo: "", sortOrder: 0)], assets: [
            .init(id: "native", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)])
        try await store.importWalletIfNeeded(.init(id: "w", name: "Synthetic", kind: "hd", vaultReference: "fixture", createdAt: 1), accounts: [
            .init(id: "a", walletID: "w", networkID: "ethereum", address: "fixture", derivationPath: "")])
        try await store.pool.write { db in
            for i in 1...3 {
                try TransactionRecord(id: "t\(i)", networkID: "ethereum", hash: "t\(i)", state: "confirmed", timestamp: Double(i), updatedAt: 1).insert(db)
                try ActivityRecord(id: "a\(i)", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "t\(i)", assetID: "native",
                    direction: "outgoing", amountAtomic: "1", counterparty: "fixture", timestamp: Double(i)).insert(db)
            }
        }
        return (store, folder)
    }

    func testSortProjectionTracksEvidenceUpdatesDeletionAndRollback() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            try db.execute(sql: "INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,outcomeAt) VALUES('a','t1',X'5B5D',0,'replaced',10)")
        }
        var page = try await store.chainHistory(walletID: "w", currency: "USD", limit: 1)
        XCTAssertEqual(page.first?.entry.id, "a1")
        XCTAssertEqual(page.first?.entry.timestamp, 10)
        XCTAssertEqual(page.first?.entry.state, "replaced")
        let next = try await store.chainHistory(walletID: "w", currency: "USD", before: .init(timestamp: 10, id: "a1"))
        XCTAssertEqual(next.map(\.id), ["a3", "a2"])
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE transactionEvidence SET outcomeAt=0 WHERE transactionID='t1'")
        }
        page = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(page.map(\.id), ["a3", "a2", "a1"])
        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM transactionEvidence WHERE transactionID='t1'")
            try db.execute(sql: "UPDATE activity SET timestamp=20 WHERE id='a1'")
        }
        page = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(page.first?.entry.timestamp, 20)
        enum Abort: Error { case rollback }
        do {
            try await store.pool.write { db in
                try db.execute(sql: "UPDATE activity SET timestamp=40 WHERE id='a2'")
                throw Abort.rollback
            }
        } catch Abort.rollback { }
        let afterRollback = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(afterRollback, page)
        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM transactions WHERE id='t1'")
        }
        let afterDelete = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(afterDelete.map(\.id), ["a3", "a2"])
    }

    func testMetadataChangesReindexSafetyWithoutLosingHistory() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE assets SET name='Claim https://fixture.invalid' WHERE id='native'")
        }
        let blocked = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertTrue(blocked.isEmpty)
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE assets SET name='Ethereum' WHERE id='native'")
        }
        let restored = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(restored.count, 3)
    }

    func testHistoryPageUsesOrderedIndexWithoutTemporarySort() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let plan = try await store.pool.read { db in
            try Row.fetchAll(db, sql: """
                EXPLAIN QUERY PLAN SELECT a.id,a.sortTimestamp FROM visibleActivity a
                JOIN transactions t ON t.id=a.transactionID
                LEFT JOIN transactionEvidence e ON e.accountID=a.accountID AND e.transactionID=a.transactionID
                WHERE a.walletID='w' ORDER BY a.sortTimestamp DESC,a.id DESC LIMIT 51
                """).map { (row: Row) -> String in row["detail"] }
        }
        XCTAssertTrue(plan.contains { $0.contains("activity_wallet_sort") }, "\(plan)")
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE FOR ORDER BY") }, "\(plan)")
    }

    func testMigrationBackfillsExistingRows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("home-index-upgrade-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { db in db.add(function: HistorySafety.metadataFunction) }
        let legacy = try DatabaseQueue(path: url.path, configuration: configuration)
        try Schema.migrator.migrate(legacy, upTo: "v57_contract_identity_cache")
        try await legacy.write { db in
            try NetworkRecord(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18, derivationPath: "", logo: "", sortOrder: 0).insert(db)
            try AssetRecord(id: "n", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18).insert(db)
            // Seed the historical schema without fields introduced by later migrations.
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES('w','Synthetic','hd','fixture',1,0)")
            try AccountRecord(id: "a", walletID: "w", networkID: "ethereum", address: "fixture", derivationPath: "").insert(db)
            try TransactionRecord(id: "t", networkID: "ethereum", hash: "t", state: "confirmed", timestamp: 1, updatedAt: 1).insert(db)
            try ActivityRecord(id: "event", walletID: "w", accountID: "a", networkID: "ethereum", transactionID: "t", assetID: "n",
                direction: "outgoing", amountAtomic: "1", counterparty: "fixture", timestamp: 1).insert(db)
            try db.execute(sql: "INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcomeAt) VALUES('a','t',X'5B5D',0,100)")
            try db.execute(sql: "INSERT INTO metadata(key,value) VALUES('walletReset','fixture-reset')")
        }
        try legacy.close()
        let store = try await OathDatabase.open(at: url)
        let page = try await store.chainHistory(walletID: "w", currency: "USD")
        XCTAssertEqual(page.first?.entry.timestamp, 100)
        XCTAssertEqual(page.count, 1)
        let reset = try await store.pendingWalletReset()
        XCTAssertEqual(reset, "fixture-reset")
        do {
            try await store.pool.write { db in try db.execute(sql: "UPDATE activity SET amountAtomic='2'") }
            XCTFail("Migration must restore the pending-reset write guard")
        } catch is DatabaseError { }
        try await store.eraseWalletData(resetID: "fixture-reset")
        try await store.finishWalletReset(resetID: "fixture-reset")
    }
}
