import Foundation
import GRDB
import Testing

struct RefundPersistenceTests {
    func item(sender: String = "alice.near") -> NEARHistoryItem {
        .init(id: "real-transfer", transactionHash: "hash", timestamp: 100,
              failed: false, sender: sender, recipient: "bob.near", metadata: nil,
              signedAmountText: "-1", networkFeeAtomic: "100000000000000000000",
              blockHeight: 100, nonce: 2)
    }

    @Test func repairsOverwrittenRowWithoutLosingNoteOrKeepingRefundValuation() throws {
        let db = try DatabaseQueue()
        try db.write { c in
            try c.execute(sql: transactionSchemaSQL)
            try c.execute(sql: "CREATE TABLE transactionNotes (transactionID TEXT PRIMARY KEY REFERENCES transactions(id) ON DELETE CASCADE, note TEXT)")
            try WalletDatabase.saveNEARHistory(database: c, accountID: "account", item: item(), now: 100)
            let original = try #require(try DBTransactionRecord.fetchOne(c))
            try c.execute(sql: "INSERT INTO transactionNotes VALUES (?, 'My note')", arguments: [original.id])
            // Reproduce what the older parser did to a real saved transaction.
            try c.execute(sql: "UPDATE transactions SET fromAddress = 'system', assetAmount = '0.00677245', fiatUSDValue = '0.02', networkFeeFiatUSDValue = '0.01'")
            try WalletDatabase.saveNEARHistory(database: c, accountID: "account", item: item(), now: 101)
            try c.execute(sql: refundCleanupSQL, arguments: ["account"])
            let restored = try #require(try DBTransactionRecord.fetchOne(c))
            #expect(restored.id == original.id)
            #expect(restored.fromAddress == "alice.near")
            #expect(restored.assetAmount == "-1")
            #expect(restored.fiatUSDValue == nil)
            #expect(restored.networkFeeFiatUSDValue == nil)
            #expect(try String.fetchOne(c, sql: "SELECT note FROM transactionNotes") == "My note")
        }
    }

    @Test func persistenceRejectsRefundAndCleanupIsScopedToNativeNEARAndAccount() throws {
        let db = try DatabaseQueue()
        try db.write { c in
            try c.execute(sql: transactionSchemaSQL)
            try WalletDatabase.saveNEARHistory(database: c, accountID: "account", item: item(sender: "system"), now: 100)
            #expect(try DBTransactionRecord.fetchCount(c) == 0)
            for account in ["account", "other"] {
                try WalletDatabase.saveNEARHistory(database: c, accountID: account, item: item(), now: 100)
            }
            try c.execute(sql: "UPDATE transactions SET fromAddress = 'system'")
            try c.execute(sql: refundCleanupSQL, arguments: ["account"])
            let rows = try DBTransactionRecord.fetchAll(c)
            #expect(rows.count == 1)
            #expect(rows.first?.accountID == "other")
            try c.execute(sql: "UPDATE transactions SET networkID = 'ethereum', accountID = 'account'")
            try c.execute(sql: refundCleanupSQL, arguments: ["account"])
            #expect(try DBTransactionRecord.fetchCount(c) == 1)
            try c.execute(sql: "UPDATE transactions SET networkID = 'near', assetID = 'near:token'")
            try c.execute(sql: refundCleanupSQL, arguments: ["account"])
            #expect(try DBTransactionRecord.fetchCount(c) == 1)
        }
    }
}
