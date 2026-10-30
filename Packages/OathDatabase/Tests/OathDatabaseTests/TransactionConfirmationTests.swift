import XCTest
import GRDB
import OathAnkr
import OathBitcoin
@testable import OathDatabase

extension ActivityDetailsTests {
    func testConfirmationDepthForEverySupportedEVMAndUTXOChain() async throws {
        let networks = AnkrChain.allCases.map(\.networkID) + ["arc", "robinhood", "hyperevm", "unichain", "monad"] + UTXONetwork.allCases.map(\.rawValue)
        for network in networks {
            let (store, url) = try await fixture(network)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await store.pool.write { db in
                try Self.confirmationFixture(db, network: network)
                try Self.confirmationHead(db, network: network, head: 105)
            }
            let details = try await store.transactionDetails(accountID: "a", transactionID: "depth")
            XCTAssertEqual(details?.confirmations, 6, network)
            try await store.pool.write { db in
                try db.execute(sql: "UPDATE transactions SET state='pending',blockHeight=NULL WHERE id='depth'")
            }
            let pending = try await store.transactionDetails(accountID: "a", transactionID: "depth")
            XCTAssertEqual(pending?.confirmations, 0, network)
        }
    }

    func testConfirmationDepthUnknownHeadsTerminalEvidenceAndOverflowBoundary() async throws {
        let (store, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.pool.write { try Self.confirmationFixture($0, network: "ethereum") }
        let missing = try await store.transactionDetails(accountID: "a", transactionID: "depth")
        XCTAssertNil(missing?.confirmations)
        try await store.pool.write { try Self.confirmationHead($0, network: "ethereum", head: 99) }
        let stale = try await store.transactionDetails(accountID: "a", transactionID: "depth")
        XCTAssertNil(stale?.confirmations, "A cached head behind inclusion is not zero confirmations")
        try await store.pool.write { db in
            try Self.confirmationHead(db, network: "ethereum", head: 100)
            try db.execute(sql: "UPDATE transactions SET state='failed' WHERE id='depth'")
        }
        let failed = try await store.transactionDetails(accountID: "a", transactionID: "depth")
        XCTAssertEqual(failed?.confirmations, 1, "Mined failures also have block depth")
        for outcome in ["canceled", "replaced", "expired", "reorged"] {
            try await store.pool.write { db in
                try db.execute(sql: "INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome) VALUES('a','depth',?,0,?) ON CONFLICT(accountID,transactionID) DO UPDATE SET outcome=excluded.outcome", arguments: [Data("[]".utf8), outcome])
            }
            let terminal = try await store.transactionDetails(accountID: "a", transactionID: "depth")
            XCTAssertNil(terminal?.confirmations, outcome)
        }
        try await store.pool.write { db in
            try db.execute(sql: "DELETE FROM transactionEvidence")
            try db.execute(sql: "UPDATE transactions SET blockHeight=1 WHERE id='depth'")
            try Self.confirmationHead(db, network: "ethereum", head: Int64.max)
        }
        let extreme = try await store.transactionDetails(accountID: "a", transactionID: "depth")
        XCTAssertEqual(extreme?.confirmations, Int64.max)
    }

    func testFinalityChainsDoNotInventConfirmationCountsFromSlotsOrVersions() async throws {
        for network in ["solana", "aptos", "sui", "near", "stellar", "xrpl", "ton", "tron", "thorchain"] {
            let (store, url) = try await fixture(network)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try await store.pool.write { db in
                try Self.confirmationFixture(db, network: network)
                // Even incidental Ankr-like metadata must not turn slots into confirmations.
                try Self.confirmationHead(db, network: "ethereum", head: 105)
            }
            let details = try await store.transactionDetails(accountID: "a", transactionID: "depth")
            XCTAssertNotNil(details)
            XCTAssertNil(details?.confirmations, network)
        }
    }

    func testConfirmationObservationIncreasesAndSurvivesReopen() async throws {
        let (store, url) = try await fixture("bitcoin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await store.pool.write { db in
            try Self.confirmationFixture(db, network: "bitcoin")
            try Self.confirmationHead(db, network: "bitcoin", head: 100)
        }
        let first = expectation(description: "Initial depth")
        let next = expectation(description: "Depth updates with only chain head change")
        let task = Task {
            var observed = false
            do {
                for try await details in store.observeTransactionDetails(accountID: "a", transactionID: "depth", currency: "USD") {
                    if details?.confirmations == 1 && !observed { observed = true; first.fulfill() }
                    if details?.confirmations == 2 { next.fulfill(); return }
                }
            } catch { XCTFail("Observation failed: \(error)") }
        }
        defer { task.cancel() }
        await fulfillment(of: [first], timeout: 5)
        try await store.pool.write { try Self.confirmationHead($0, network: "bitcoin", head: 101) }
        await fulfillment(of: [next], timeout: 5)
        let reopened = try await OathDatabase.open(at: url)
        let persisted = try await reopened.transactionDetails(accountID: "a", transactionID: "depth")
        XCTAssertEqual(persisted?.confirmations, 2)
        let wrongAccount = try await reopened.transactionDetails(accountID: "other", transactionID: "depth")
        XCTAssertNil(wrongAccount)
    }

    private nonisolated static func confirmationFixture(_ db: Database, network: String) throws {
        try TransactionRecord(id: "depth", networkID: network, hash: "public-hash", state: "confirmed", blockHeight: 100, timestamp: 1, updatedAt: 1).insert(db)
        try ActivityRecord(id: "depth", walletID: "w", accountID: "a", networkID: network, transactionID: "depth", assetID: network + ":native", direction: "outgoing", amountAtomic: "1", counterparty: "public-recipient", timestamp: 1).insert(db)
    }

    private nonisolated static func confirmationHead(_ db: Database, network: String, head: Int64) throws {
        if UTXONetwork(rawValue: network) != nil {
            try db.execute(sql: "INSERT INTO bitcoinWallets(accountID,descriptor,preferredType,tipHeight) VALUES('a',?,0,?) ON CONFLICT(accountID) DO UPDATE SET tipHeight=excluded.tipHeight", arguments: [Data(), head])
        } else if ["arc", "robinhood", "hyperevm", "unichain", "monad"].contains(network) {
            let table = ["unichain", "monad"].contains(network) ? "indexedEVMSync" : network + "Sync"
            try db.execute(sql: "INSERT INTO \(table)(accountID,runID,checkpoint) VALUES('a','fixture',?) ON CONFLICT(accountID) DO UPDATE SET checkpoint=excluded.checkpoint", arguments: [head])
        } else {
            let status = try JSONSerialization.data(withJSONObject: ["blockNumber": head])
            try db.execute(sql: "INSERT INTO ankrSync(accountID,stream,syncStatus) VALUES('a','transactions',?) ON CONFLICT(accountID,stream) DO UPDATE SET syncStatus=excluded.syncStatus", arguments: [status])
        }
    }
}
