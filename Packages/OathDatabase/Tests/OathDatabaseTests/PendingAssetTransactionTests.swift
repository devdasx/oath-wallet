import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class PendingAssetTransactionTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pending-assets-" + UUID().uuidString)
        let store = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let networks = ["ethereum", "aptos", "bitcoin", "litecoin", "dogecoin", "bitcoincash", "solana"]
        try await store.seed(networks: networks.enumerated().map { index, id in
            .init(id: id, name: id, family: "fixture", symbol: "COIN", decimals: 8, derivationPath: "", logo: "", sortOrder: index)
        }, assets: networks.flatMap { network in
            ["native", "token", "other-token"].map {
                AssetRecord(id: network + ":" + $0, networkID: network, reference: $0, name: $0, symbol: "TEST", decimals: 8)
            }
        })
        for wallet in ["first", "second"] {
            try await store.importWalletIfNeeded(.init(id: wallet, name: wallet, kind: "hd", vaultReference: wallet, createdAt: 1), accounts: networks.map {
                .init(id: wallet + ":" + $0, walletID: wallet, networkID: $0, address: "public-owner", derivationPath: "")
            })
        }
        try await store.pool.write { db in
            for wallet in ["first", "second"] {
                for network in networks {
                    for reference in ["token", "other-token"] {
                        try db.execute(sql: "INSERT INTO trackedAssets(accountID,assetID,networkID,addedAt) VALUES(?,?,?,1)", arguments: [wallet + ":" + network, network + ":" + reference, network])
                    }
                }
            }
        }
        return (store, folder)
    }

    private nonisolated static func insert(_ db: Database, id: String, network: String = "ethereum", wallet: String = "first", asset: String = "native", state: String = "pending", owner: String = "public-owner") throws {
        try TransactionRecord(id: id, networkID: network, hash: id, state: state, timestamp: 1, updatedAt: 1).insert(db)
        try ActivityRecord(id: id, walletID: wallet, accountID: wallet + ":" + network, networkID: network, transactionID: id, assetID: network + ":" + asset, direction: "outgoing", amountAtomic: "1", counterparty: "public-recipient", timestamp: 1).insert(db)
        if network == "solana" {
            try db.execute(sql: "INSERT INTO solanaActivity(activityID,owner) VALUES(?,?)", arguments: [id, owner])
        }
    }

    private func count(_ store: OathDatabase, network: String = "ethereum", asset: String = "native", wallet: String = "first") async throws -> Int {
        let snapshot = try await store.snapshot(walletID: wallet, currency: "USD")
        return try XCTUnwrap(snapshot.holdings.first { $0.assetID == network + ":" + asset }).pendingTransactionCount
    }

    func testCountsDistinctTransactionsPerAssetWalletAndChain() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            try Self.insert(db, id: "native")
            try Self.insert(db, id: "token-one", asset: "token")
            try Self.insert(db, id: "token-two", asset: "token")
            try Self.insert(db, id: "same-ticker", asset: "other-token")
            try Self.insert(db, id: "other-wallet", wallet: "second")
            try Self.insert(db, id: "other-chain", network: "aptos")
            try Self.insert(db, id: "confirmed", state: "confirmed")
            try ActivityRecord(id: "duplicate-event", walletID: "first", accountID: "first:ethereum", networkID: "ethereum", transactionID: "token-one", assetID: "ethereum:token", direction: "incoming", amountAtomic: "2", counterparty: "public-sender", timestamp: 1).insert(db)
        }
        let native = try await count(store), token = try await count(store, asset: "token")
        let other = try await count(store, asset: "other-token"), wallet = try await count(store, wallet: "second")
        let aptos = try await count(store, network: "aptos")
        XCTAssertEqual(native, 1); XCTAssertEqual(token, 2); XCTAssertEqual(other, 1)
        XCTAssertEqual(wallet, 1); XCTAssertEqual(aptos, 1)
    }

    func testTerminalOutcomesRemoveCountsWithoutChangingBalances() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for outcome in ["confirmed", "failed", "canceled", "replaced", "expired"] {
            try await store.pool.write { try Self.insert($0, id: outcome) }
            let before = try await count(store)
            XCTAssertEqual(before, 1)
            try await store.pool.write { db in
                if ["confirmed", "failed"].contains(outcome) {
                    try db.execute(sql: "UPDATE transactions SET state=? WHERE id=?", arguments: [outcome, outcome])
                } else {
                    try db.execute(sql: "INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,outcomeAt) VALUES('first:ethereum',?,?,0,?,2)", arguments: [outcome, Data("[]".utf8), outcome])
                }
            }
            let after = try await count(store)
            XCTAssertEqual(after, 0, outcome)
        }
    }

    func testUTXOHistoryBeforeDecodedActivityAndDeduplication() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        for network in ["bitcoin", "litecoin", "dogecoin", "bitcoincash"] {
            try await store.pool.write { db in
                try db.execute(sql: "INSERT INTO bitcoinWallets(accountID,descriptor,preferredType) VALUES(?,?,0)", arguments: ["first:" + network, Data()])
                try db.execute(sql: "INSERT INTO bitcoinHistory(accountID,txid,height) VALUES(?,?,-1)", arguments: ["first:" + network, network])
            }
            let historyOnly = try await count(store, network: network)
            XCTAssertEqual(historyOnly, 1)
            try await store.pool.write { try Self.insert($0, id: network, network: network) }
            let decoded = try await count(store, network: network)
            XCTAssertEqual(decoded, 1)
            try await store.pool.write { db in
                try db.execute(sql: "UPDATE bitcoinHistory SET height=100 WHERE txid=?", arguments: [network])
            }
            let confirmed = try await count(store, network: network)
            XCTAssertEqual(confirmed, 0, "Confirmed history beats stale pending activity")
        }
    }

    func testSolanaCountsOnlySelectedReceiveOwner() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { db in
            try Self.insert(db, id: "current", network: "solana")
            try Self.insert(db, id: "old", network: "solana", owner: "old-owner")
        }
        let pending = try await count(store, network: "solana")
        XCTAssertEqual(pending, 1)
    }

    func testPortfolioObserverPublishesConfirmationWithoutBalanceChange() async throws {
        let (store, folder) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await store.pool.write { try Self.insert($0, id: "observed") }
        let updated = expectation(description: "Pending count clears in observed portfolio")
        let initial = expectation(description: "Initial pending count")
        let task = Task {
            var sawPending = false
            do {
                for try await snapshot in store.observeWallet(walletID: "first", currency: "USD") {
                    let row = snapshot.holdings.first { $0.assetID == "ethereum:native" }
                    if row?.pendingTransactionCount == 1 && !sawPending {
                        sawPending = true; initial.fulfill()
                    } else if sawPending && row?.pendingTransactionCount == 0 {
                        updated.fulfill(); return
                    }
                }
            } catch { XCTFail("Observation failed: \(error)") }
        }
        defer { task.cancel() }
        await fulfillment(of: [initial], timeout: 5)
        try await store.pool.write { try $0.execute(sql: "UPDATE transactions SET state='confirmed' WHERE id='observed'") }
        await fulfillment(of: [updated], timeout: 5)
    }
}
