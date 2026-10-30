import Foundation
import XCTest
import GRDB
@testable import OathDatabase

/// Opt-in, synthetic data only. Exercises the real repository and WAL pool.
@MainActor final class HomeIndexPerformanceTests: XCTestCase {
    func testLargeWalletReadWriteWorkload() async throws {
        guard ProcessInfo.processInfo.environment["OATH_HOME_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in host benchmark")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oath-index-benchmark-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let missing = try await store.pool.read { db in
            var missing: [String] = []
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
            for table in tables {
                let complete = Set(try Row.fetchAll(db, sql: "PRAGMA index_list(\(table.quotedDatabaseIdentifier))")
                    .filter { (row: Row) in !(row["partial"] as Bool) }.map { (row: Row) -> String in row["name"] })
                let indexes = try db.indexes(on: table).filter { complete.contains($0.name) }.map(\.columns) + [try db.primaryKey(table).columns]
                for key in try db.foreignKeys(on: table) {
                    let columns = Set(key.originColumns)
                    if !indexes.contains(where: { $0.first.map(columns.contains) == true }) {
                        missing.append(table + "(" + key.originColumns.joined(separator: ",") + ")")
                    }
                }
            }
            return missing
        }
        print("HOME_INDEX_AUDIT missing_foreign_key_prefixes=\(missing)")
        XCTAssertTrue(missing.isEmpty, "Unindexed relationship lookups must not scan chain ledgers")
        try await store.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH",
            decimals: 18, derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [
            .init(id: "native", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18)])
        for i in 0..<4 {
            try await store.importWalletIfNeeded(.init(id: "w\(i)", name: "Synthetic", kind: "hd", vaultReference: "fixture\(i)", createdAt: 1),
                accounts: [.init(id: "a\(i)", walletID: "w\(i)", networkID: "ethereum", address: "fixture\(i)", derivationPath: "")])
        }
        try await store.pool.write { db in
            for i in 0..<250 {
                let id = "token\(i)"
                try AssetRecord(id: id, networkID: "ethereum", reference: id, name: "Token \(i)", symbol: "T\(i)", decimals: 6).insert(db)
                try HistorySafety.trust(networkID: "ethereum", reference: id, decimals: 6, source: "fixture", observedAt: 1, db: db)
                try PriceRecord(assetID: id, currency: "USD", value: "1", observedAt: 1, source: "fixture").insert(db)
                for wallet in 0..<4 {
                    try BalanceRecord(accountID: "a\(wallet)", assetID: id, networkID: "ethereum", amountAtomic: "1000000", observedAt: 1, source: "fixture").insert(db)
                }
            }
            for i in 0..<20_000 {
                let id = "tx\(i)", wallet = i % 4
                try TransactionRecord(id: id, networkID: "ethereum", hash: id, state: "confirmed", timestamp: Double(i), updatedAt: 1).insert(db)
                try ActivityRecord(id: id, walletID: "w\(wallet)", accountID: "a\(wallet)", networkID: "ethereum", transactionID: id,
                    assetID: "token\(i % 250)", direction: "incoming", amountAtomic: "1000000", counterparty: "fixture", timestamp: Double(i)).insert(db)
            }
        }
        for kind in ["portfolio", "history"] {
            var times: [Double] = []
            for _ in 0..<8 {
                let start = Date()
                if kind == "portfolio" {
                    let value = try await store.snapshot(walletID: "w0", currency: "USD")
                    XCTAssertEqual(value.holdings.count, 251)
                    XCTAssertEqual(value.holdings.reduce(0) { $0 + $1.transactionCount }, 5_000)
                } else {
                    let page = try await store.chainHistory(walletID: "w0", currency: "USD", limit: 51)
                    XCTAssertEqual(page.count, 51)
                    XCTAssertEqual(page.first?.entry.timestamp, 19_996)
                }
                times.append(Date().timeIntervalSince(start) * 1_000)
            }
            print("HOME_BENCHMARK \(kind) rows=20000 assets=1000 median_ms=\(times.sorted()[4]) max_ms=\(times.max()!)")
        }
        let delivered = expectation(description: "Committed balance reaches live observer")
        var deliveries = 0
        let observer = Task {
            for try await snapshot in store.observeWallet(walletID: "w0", currency: "USD") {
                deliveries += 1
                if snapshot.holdings.first(where: { $0.assetID == "native" })?.amountAtomic == "40" {
                    delivered.fulfill()
                    break
                }
            }
        }
        let writer = Task {
            for i in 1...40 {
                try await store.saveBalances([.init(accountID: "a0", assetID: "native", networkID: "ethereum",
                    amountAtomic: String(i), observedAt: Double(i), source: "fixture")])
                _ = try await store.chainHistory(walletID: "w0", currency: "USD", limit: 51)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // This is executor latency on the host, not a device FPS assertion.
        var maximumHeartbeatMS = 0.0
        for _ in 0..<200 {
            let start = Date()
            try await Task.sleep(for: .milliseconds(2))
            maximumHeartbeatMS = max(maximumHeartbeatMS, Date().timeIntervalSince(start) * 1_000)
        }
        try await writer.value
        await fulfillment(of: [delivered], timeout: 10)
        observer.cancel()
        try await observer.value
        let persisted = try await store.balance(accountID: "a0", assetID: "native")
        XCTAssertEqual(persisted?.amountAtomic, "40")
        print("HOME_CONCURRENT writes=40 live_deliveries=\(deliveries) max_host_heartbeat_ms=\(maximumHeartbeatMS)")
    }
}
