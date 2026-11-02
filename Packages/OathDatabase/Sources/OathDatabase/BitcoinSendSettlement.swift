import Foundation
import GRDB
import OathBitcoin

extension OathDatabase {
    public func settleBitcoinSend(_ id: String, confirmation: BitcoinSendConfirmation) async throws {
        guard confirmation.height > 0, confirmation.timestamp.isFinite, confirmation.timestamp > 0 else { throw BitcoinError.invalidResponse }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db, key: id), ["signed", "broadcast"].contains(send.state) else { return }
            guard let chain = UTXONetwork(rawValue: send.networkID), let payload = send.signedPayload,
                  let txID = send.transactionID, var original = try TransactionRecord.fetchOne(db, key: txID),
                  let bytes = try Data.fetchOne(db, sql: "SELECT plan FROM bitcoinSendPlans WHERE sendID=?", arguments: [id]) else { throw StoreError.missingRecord }
            let plan = try JSONDecoder().decode(BitcoinSendPlan.self, from: bytes)
            let saved = try BitcoinTransactions.details(payload, network: chain)
            let mined = try BitcoinTransactions.details(confirmation.raw, network: chain)
            let keys = Set(saved.inputs.map(\.outpoint)), minedKeys = Set(mined.inputs.map(\.outpoint))
            guard plan.chain == chain, original.hash == saved.txid, txID == chain.rawValue + ":" + saved.txid,
                  keys == Set(plan.coins.map(\.id)), !keys.isEmpty, !keys.isDisjoint(with: minedKeys) else { throw BitcoinSendError.changed }
            let now = Date.now.timeIntervalSince1970
            if mined.txid == saved.txid {
                guard confirmation.raw == payload else { throw BitcoinSendError.changed }
                original.state = "confirmed"; original.blockHeight = confirmation.height
                original.timestamp = confirmation.timestamp; original.updatedAt = now
                try original.update(db)
                send.state = "confirmed"
            } else {
                let winner = TransactionRecord(id: chain.rawValue + ":" + mined.txid, networkID: chain.rawValue,
                    hash: mined.txid, state: "confirmed", blockHeight: confirmation.height,
                    timestamp: confirmation.timestamp, updatedAt: now)
                // Preserve richer history/fee data if the normal sync saw it first.
                try db.execute(sql: """
                    INSERT INTO transactions(id,networkID,hash,state,blockHeight,timestamp,updatedAt) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(id) DO UPDATE SET state='confirmed',blockHeight=excluded.blockHeight,
                        timestamp=excluded.timestamp,updatedAt=excluded.updatedAt
                    """, arguments: [winner.id,winner.networkID,winner.hash,winner.state,winner.blockHeight,winner.timestamp,now])
                let scripts = Set(try String.fetchAll(db, sql: """
                    SELECT b.script FROM bitcoinAddresses b JOIN walletAccounts a ON a.id=b.accountID
                    WHERE a.walletID=? AND a.networkID=?
                    """, arguments: [send.walletID, send.networkID]))
                let returned = minedKeys.isSubset(of: keys) && !mined.outputs.isEmpty && mined.outputs.allSatisfy { scripts.contains($0.script) }
                for account in Set(plan.coins.map(\.accountID)).union([send.accountID]) {
                    try Self.saveTransactionEvidence(accountID: account, tx: winner, keys: minedKeys, returnsToWallet: returned, db: db)
                }
                original.state = "replaced"; original.updatedAt = now; try original.update(db)
                send.state = "failed"; send.failureCode = returned ? "canceled" : "replaced"
            }
            send.updatedAt = now; try send.update(db) // Deletes the status job atomically.
            for input in mined.inputs {
                try db.execute(sql: "UPDATE utxos SET spent=1 WHERE networkID=? AND transactionHash=? AND outputIndex=?",
                    arguments: [send.networkID,input.txid,input.index])
            }
            try db.execute(sql: "UPDATE utxos SET reservedBy=NULL WHERE reservedBy=?", arguments: [id])
            try db.execute(sql: """
                INSERT INTO sendBalanceRefreshes(sendID) VALUES(?)
                ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL
                """, arguments: [id])
        }
    }
}
