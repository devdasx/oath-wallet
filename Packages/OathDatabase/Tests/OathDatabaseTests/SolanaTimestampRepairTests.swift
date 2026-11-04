import Foundation
import GRDB
import XCTest
@testable import OathAnkr
@testable import OathDatabase

@MainActor final class SolanaTimestampRepairTests: XCTestCase {
    nonisolated private static let owner = "HAgk14JpMQLgt6rVgv7cBQFJWFto5Dqxi472uT3DKpqk"
    nonisolated private static let baseTime: UInt64 = 1_793_649_600

    private func legacyDatabase() throws -> (DatabaseQueue, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SolanaTime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase {
            $0.add(function: HistorySafety.metadataFunction)
            $0.add(function: ReceiveQRImage.function)
        }
        let queue = try DatabaseQueue(path: folder.appendingPathComponent("wallet.sqlite").path, configuration: configuration)
        try Schema.migrator.migrate(queue, upTo: "v104_existing_wallet_backup_offers")
        return (queue, folder)
    }

    nonisolated private static func seed(_ db: Database, count: Int) throws {
        for network in ["solana", "bitcoin"] {
            try NetworkRecord(id: network, name: network, family: "account", symbol: "SOL", decimals: 9,
                              derivationPath: "", logo: "", sortOrder: 0).insert(db)
            try AssetRecord(id: network + ":native", networkID: network, reference: "native", name: network, symbol: "SOL", decimals: 9).insert(db)
        }
        for index in 1...2 {
            try WalletRecord(id: "w\(index)", name: "Fixture", kind: "hd", vaultReference: "fixture\(index)", createdAt: 1).insert(db)
            try AccountRecord(id: "a\(index)", walletID: "w\(index)", networkID: "solana", address: owner, derivationPath: "").insert(db)
        }
        for index in 0..<count {
            let seconds = baseTime + UInt64(index * 86_400)
            let broken = Double(bitPattern: seconds)
            let signature = "fixture-\(index)"
            try TransactionRecord(id: "solana:" + signature, networkID: "solana", hash: signature, state: "confirmed",
                                  blockHeight: Int64(100 + index), timestamp: broken, feeAtomic: "5000", updatedAt: 99).insert(db)
            for wallet in 1...2 {
                let activityID = "a\(wallet):\(owner):\(signature):native"
                let direction = index.isMultiple(of: 2) ? "incoming" : "outgoing"
                try ActivityRecord(id: activityID, walletID: "w\(wallet)", accountID: "a\(wallet)", networkID: "solana",
                                   transactionID: "solana:" + signature, assetID: "solana:native", direction: direction,
                                   amountAtomic: "9007199254740993", counterparty: "", timestamp: broken).insert(db)
                try db.execute(sql: "INSERT INTO solanaActivity VALUES(?,?)", arguments: [activityID, owner])
                let cached = SolanaTransaction(signature: signature, slot: UInt64(100 + index), timestamp: broken, failed: false,
                    fee: "5000", changes: [.init(mint: "native", decimals: 9, amount: "9007199254740993", direction: direction)],
                    tokenAccounts: [], raw: Data("{\"blockTime\":\(seconds)}".utf8))
                try db.execute(sql: "INSERT INTO solanaTransactions VALUES(?,?,?,?)",
                               arguments: ["a\(wallet)", owner, signature, try JSONEncoder().encode(cached)])
            }
        }
        // The same bad numeric shape on another chain must not be rewritten.
        try TransactionRecord(id: "bitcoin:keep", networkID: "bitcoin", hash: "keep", state: "confirmed",
                              timestamp: Double(bitPattern: baseTime), feeAtomic: "123", updatedAt: 99).insert(db)
        try TransactionRecord(id: "solana:correct", networkID: "solana", hash: "correct", state: "confirmed",
                              timestamp: Double(baseTime), feeAtomic: "5000", updatedAt: 99).insert(db)
        try TransactionRecord(id: "solana:unknown", networkID: "solana", hash: "unknown", state: "confirmed",
                              timestamp: 0, feeAtomic: "5000", updatedAt: 99).insert(db)
    }

    func testUpgradeRestoresExactDatesAcrossWalletsPagesAndCachedReceipts() async throws {
        let (queue, folder) = try legacyDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Cross both the scalar (128) and receipt (16) migration batch boundaries.
        let count = 140
        try await queue.write { try Self.seed($0, count: count) }
        try queue.close()
        let url = folder.appendingPathComponent("wallet.sqlite")
        for _ in 0..<2 {
            let database = try await OathDatabase.open(at: url)
            for wallet in 1...2 {
                var entries: [HistoryEntry] = []
                var cursor: HistoryCursor?
                while true {
                    let page = try await database.history(walletID: "w\(wallet)", before: cursor, limit: 17)
                    guard let last = page.last else { break }
                    entries += page
                    cursor = .init(timestamp: last.timestamp, id: last.id)
                    guard entries.count <= count else { return XCTFail("Pagination duplicated history") }
                }
                XCTAssertEqual(entries.count, count)
                XCTAssertEqual(Set(entries.map(\.id)).count, count)
                XCTAssertEqual(entries.map(\.timestamp), (0..<count).reversed().map { Double(Self.baseTime + UInt64($0 * 86_400)) })
                XCTAssertTrue(entries.allSatisfy { $0.amountAtomic == "9007199254740993" })
                let ticket = try await database.beginSolanaSync(accountID: "a\(wallet)")
                let cached = try await database.cachedSolanaTransactions(ticket, signatures: (0..<count).map { "fixture-\($0)" })
                XCTAssertEqual(cached.count, count)
                for (index, receipt) in cached.enumerated() {
                    let seconds = Self.baseTime + UInt64(index * 86_400)
                    XCTAssertEqual(receipt.timestamp, Double(seconds))
                    XCTAssertEqual(receipt.raw, Data("{\"blockTime\":\(seconds)}".utf8))
                    XCTAssertEqual(receipt.changes.first?.amount, "9007199254740993")
                    XCTAssertEqual(receipt.fee, "5000")
                    XCTAssertEqual(receipt.slot, UInt64(100 + index))
                }
                let latest = try XCTUnwrap(cached.last)
                let work = try await database.solanaHistoryWork(ticket, since: .greatestFiniteMagnitude)
                let syncCursor = try XCTUnwrap(work.first)
                try await database.commitSolanaHistory([latest], page: .init(signatures: [
                    .init(signature: latest.signature, slot: latest.slot, blockTime: latest.timestamp, failed: false)
                ], archival: true), cursor: syncCursor, ticket: ticket, backfill: false, pageSize: 20, catalog: [:])
                let refreshed = try await database.history(walletID: "w\(wallet)", limit: 1)
                XCTAssertEqual(refreshed.first?.timestamp, latest.timestamp, "Reusing the cache must not reintroduce the epoch date")
            }
            let transaction = try await database.transaction("solana:fixture-0")
            XCTAssertEqual(transaction?.timestamp, Double(Self.baseTime))
            XCTAssertEqual(transaction?.updatedAt, 99)
            let bitcoin = try await database.transaction("bitcoin:keep")
            XCTAssertEqual(bitcoin?.timestamp, Double(bitPattern: Self.baseTime))
            let correct = try await database.transaction("solana:correct")
            XCTAssertEqual(correct?.timestamp, Double(Self.baseTime))
            let unknown = try await database.transaction("solana:unknown")
            XCTAssertEqual(unknown?.timestamp, 0)
            let remaining = try await database.pool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity WHERE networkID='solana' AND timestamp<>sortTimestamp")
            }
            XCTAssertEqual(remaining, 0)
        }
    }

    func testOnlyTheLegacyBitPatternIsRecoverable() {
        for value in [0, -1, 1_793_649_600, Double.infinity, Double.nan, Double.leastNormalMagnitude, Double(bitPattern: 253_402_300_800)] {
            XCTAssertNil(SolanaTimestampRepair.recoveredSeconds(value))
        }
        for seconds: UInt64 in [1_700_000_000, Self.baseTime, 2_200_000_000] {
            XCTAssertEqual(SolanaTimestampRepair.recoveredSeconds(Double(bitPattern: seconds)), Double(seconds))
        }
    }

    func testUpgradePreservesInterruptedResetAndAllowsItToFinish() async throws {
        let (queue, folder) = try legacyDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await queue.write { db in
            try Self.seed(db, count: 1)
            try db.execute(sql: "INSERT INTO metadata VALUES('walletReset','fixture-reset')")
        }
        try queue.close()
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await database.eraseWalletData(resetID: "fixture-reset")
        try await database.finishWalletReset(resetID: "fixture-reset")
        let wallets = try await database.wallets()
        XCTAssertTrue(wallets.isEmpty)
    }

    func testFailedMigrationRollsBackAndCanRetryWithoutPartialRepair() async throws {
        let (queue, folder) = try legacyDatabase()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await queue.write { db in
            try Self.seed(db, count: 1)
            try db.execute(sql: """
                CREATE TRIGGER fail_time_repair BEFORE UPDATE OF timestamp ON activity
                BEGIN SELECT RAISE(ABORT,'fixture write failure'); END
                """)
        }
        let url = folder.appendingPathComponent("wallet.sqlite")
        do {
            _ = try await OathDatabase.open(at: url)
            XCTFail("The fixture write must fail")
        } catch { }
        let state = try await queue.read { db in
            (try Double.fetchOne(db, sql: "SELECT timestamp FROM transactions WHERE id='solana:fixture-0'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='v107_solana_unix_timestamps'"))
        }
        XCTAssertEqual(state.0, Double(bitPattern: Self.baseTime))
        XCTAssertEqual(state.1, 0)
        try await queue.write { try $0.execute(sql: "DROP TRIGGER fail_time_repair") }
        try queue.close()
        let database = try await OathDatabase.open(at: url)
        let transaction = try await database.transaction("solana:fixture-0")
        XCTAssertEqual(transaction?.timestamp, Double(Self.baseTime))
    }
}
