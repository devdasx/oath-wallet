import Foundation
import GRDB
import OathBitcoin

public struct SyncBatch: Sendable {
    public var cursor: SyncCursor
    public var expectedCursor: String?
    public var expectedGeneration: Int64
    public var balances: [BalanceRecord] = []
    public var transactions: [TransactionRecord] = []
    public var transfers: [TransferRecord] = []
    public var activity: [ActivityRecord] = []
    public var utxos: [UTXORecord] = []
    public init(cursor: SyncCursor, expectedCursor: String?, expectedGeneration: Int64 = 0) {
        self.cursor = cursor; self.expectedCursor = expectedCursor; self.expectedGeneration = expectedGeneration
    }
}

public struct RecordPageCursor: Sendable {
    public let timestamp: Double
    public let id: String
    public init(timestamp: Double, id: String) { self.timestamp = timestamp; self.id = id }
}
public typealias HistoryCursor = RecordPageCursor

public struct OutputCursor: Sendable {
    public let value: Int64
    public let hash: String
    public let index: Int
    public init(value: Int64, hash: String, index: Int) {
        self.value = value; self.hash = hash; self.index = index
    }
}

public struct HistoryEntry: Decodable, FetchableRecord, Sendable, Equatable {
    public let id: String
    public let accountID: String
    public let networkID: String
    public let transactionID: String
    public let assetID: String
    public let direction: String
    public let amountAtomic: String
    public let counterparty: String
    public let timestamp: Double
    public let state: String
    public let hash: String
    /// Display-only wallet debit; the original transfer amount stays available.
    public var contractKind: String? = nil
    public var usesSelfTransferFee: Bool? = nil
    public var selfTransferFeeAtomic: String? = nil
    public var displayAmountAtomic: String? { usesSelfTransferFee == true ? selfTransferFeeAtomic : amountAtomic }
    public var displayDirection: String {
        if usesSelfTransferFee == true || direction == "bridgeOutgoing" { return "outgoing" }
        return direction == "bridgeIncoming" ? "incoming" : direction
    }

    /// Keep the selected activity identity/amount while its observed outcome changes.
    public func updatingState(_ state: String) -> Self {
        .init(id: id, accountID: accountID, networkID: networkID, transactionID: transactionID,
              assetID: assetID, direction: direction, amountAtomic: amountAtomic,
              counterparty: counterparty, timestamp: timestamp, state: state, hash: hash,
              contractKind: contractKind, usesSelfTransferFee: usesSelfTransferFee, selfTransferFeeAtomic: selfTransferFeeAtomic)
    }
}

extension OathDatabase {
    /// Page contents and the resume cursor commit together. An old response
    /// cannot overwrite a newer sync. Retrying the same cursor is idempotent.
    @discardableResult
    public func apply(_ batch: SyncBatch) async throws -> Bool {
        guard batch.balances.count + batch.transactions.count + batch.transfers.count + batch.activity.count + batch.utxos.count <= 2_000,
              !batch.cursor.cursor.isEmpty, !batch.cursor.stream.isEmpty,
              batch.cursor.updatedAt.isFinite else { throw StoreError.invalidValue("sync page") }
        return try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: batch.cursor.accountID) else { throw StoreError.missingRecord }
            guard account.syncGeneration == batch.expectedGeneration else { throw StoreError.staleSync }
            let existing = try SyncCursor.fetchOne(db, sql: "SELECT * FROM syncCursors WHERE accountID=? AND stream=?",
                                                   arguments: [account.id, batch.cursor.stream])
            if existing?.cursor == batch.cursor.cursor { return false }
            guard existing?.cursor == batch.expectedCursor else { throw StoreError.staleSync }
            for balance in batch.balances {
                guard balance.accountID == account.id, balance.networkID == account.networkID else { throw StoreError.conflictingIdentity }
                try Self.saveBalance(balance, db: db)
            }
            let isEVM = try String.fetchOne(db, sql: "SELECT family FROM networks WHERE id=?", arguments: [account.networkID]) == "evm"
            for incoming in batch.transactions {
                var transaction = incoming
                guard transaction.networkID == account.networkID else { throw StoreError.conflictingIdentity }
                guard transaction.timestamp.isFinite, transaction.updatedAt.isFinite, !transaction.hash.isEmpty else { throw StoreError.invalidValue("transaction") }
                if let amount = transaction.feeAtomic { try Validation.amount(amount) }
                if let old = try TransactionRecord.fetchOne(db, key: transaction.id) {
                    guard old.networkID == transaction.networkID, old.hash == transaction.hash else { throw StoreError.conflictingIdentity }
                    if old.updatedAt > transaction.updatedAt { continue }
                    if isEVM { transaction = transaction.retainingEVMReceipt(from: old) }
                }
                try transaction.upsert(db)
            }
            for transfer in batch.transfers {
                guard transfer.networkID == account.networkID else { throw StoreError.conflictingIdentity }
                try Validation.amount(transfer.amountAtomic)
                if let old = try TransferRecord.fetchOne(db, key: transfer.id) {
                    guard old.transactionID == transfer.transactionID, old.assetID == transfer.assetID,
                          old.eventIndex == transfer.eventIndex else { throw StoreError.conflictingIdentity }
                }
                try transfer.upsert(db)
            }
            for item in batch.activity {
                guard item.walletID == account.walletID, item.accountID == account.id,
                      item.networkID == account.networkID else { throw StoreError.conflictingIdentity }
                try Validation.amount(item.amountAtomic)
                guard item.timestamp.isFinite else { throw StoreError.invalidValue("activity timestamp") }
                if let old = try ActivityRecord.fetchOne(db, key: item.id) {
                    guard old.accountID == item.accountID, old.transactionID == item.transactionID,
                          old.assetID == item.assetID else { throw StoreError.conflictingIdentity }
                }
                try item.upsert(db)
            }
            for output in batch.utxos {
                guard output.accountID == account.id, output.networkID == account.networkID,
                      output.reservedBy == nil else { throw StoreError.conflictingIdentity }
                guard output.updatedAt.isFinite, !output.transactionHash.isEmpty else { throw StoreError.invalidValue("output") }
                // Network responses may change spent/confirmation state, but
                // can never clear a locally reserved input while signing.
                if let old = try UTXORecord.fetchOne(db, sql: "SELECT *,? AS accountID FROM utxos WHERE networkID=? AND transactionHash=? AND outputIndex=?",
                    arguments: [account.id, output.networkID, output.transactionHash, output.outputIndex]) {
                    guard old.value == output.value, old.script == output.script else {
                        throw StoreError.conflictingIdentity
                    }
                }
                try db.execute(sql: """
                    INSERT INTO utxos(networkID,transactionHash,outputIndex,value,script,blockHeight,spent,updatedAt)
                    VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT(networkID,transactionHash,outputIndex) DO UPDATE SET
                    blockHeight=excluded.blockHeight,spent=excluded.spent,updatedAt=excluded.updatedAt
                    WHERE excluded.updatedAt>=utxos.updatedAt
                    """, arguments: [output.networkID, output.transactionHash, output.outputIndex, output.value,
                                      output.script, output.blockHeight, output.spent, output.updatedAt])
                try db.execute(sql: "INSERT OR IGNORE INTO accountUTXOs(accountID,networkID,transactionHash,outputIndex) VALUES (?,?,?,?)",
                               arguments: [account.id, output.networkID, output.transactionHash, output.outputIndex])
            }
            try batch.cursor.upsert(db)
            return true
        }
    }

    /// For trusted local imports. Network refreshes use apply/SyncCoordinator
    /// so their data and cursor also receive the reorg-generation check.
    public func saveBalances(_ balances: [BalanceRecord]) async throws {
        guard balances.count <= 2_000 else { throw StoreError.invalidValue("balance batch") }
        try await pool.write { db in for balance in balances { try Self.saveBalance(balance, db: db) } }
    }
    private static func saveBalance(_ balance: BalanceRecord, db: Database) throws {
        try Validation.amount(balance.amountAtomic)
        guard balance.observedAt.isFinite else { throw StoreError.invalidValue("balance timestamp") }
        if let old = try BalanceRecord.fetchOne(db, key: ["accountID": balance.accountID, "assetID": balance.assetID]) {
            guard old.networkID == balance.networkID else { throw StoreError.conflictingIdentity }
            if old.observedAt > balance.observedAt { return }
        }
        try balance.upsert(db)
    }
    public func balance(accountID: String, assetID: String) async throws -> BalanceRecord? {
        try await pool.read { db in
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "solana" {
                return try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'solana' AS networkID,amountAtomic,observedAt,
                           slot AS blockHeight,'solana' AS source FROM solanaHoldings
                    WHERE accountID=? AND owner=? AND assetID=?
                    """, arguments: [accountID, Self.solanaOwner(account, db: db), assetID])
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "tron" {
                return try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'tron' AS networkID,amountAtomic,observedAt,NULL AS blockHeight,'tron' AS source
                    FROM tronHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID])
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "ton" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'ton' AS networkID,amountAtomic,observedAt,NULL AS blockHeight,'ton' AS source
                    FROM tonHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "aptos" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'aptos' AS networkID,amountAtomic,observedAt,NULL AS blockHeight,'aptos' AS source
                    FROM aptosHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "sui" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'sui' AS networkID,amountAtomic,observedAt,NULL AS blockHeight,'sui' AS source
                    FROM suiHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "xrpl" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'xrpl' AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'xrpl' AS source
                    FROM xrplHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "polkadot" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'polkadot' AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'polkadot' AS source
                    FROM polkadotHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "stellar" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'stellar' AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'stellar' AS source
                    FROM stellarHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "near" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'near' AS networkID,amountAtomic,observedAt,blockHeight,'near' AS source
                    FROM nearHoldings WHERE accountID=? AND assetID=? AND amountAtomic IS NOT NULL
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), ["chiliz", "filecoin", "sei", "zerog", "iotex", "celo", "unichain", "monad"].contains(account.networkID) {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,? AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'indexedEVM' AS source
                    FROM indexedEVMHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [account.networkID,accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "hyperevm" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'hyperevm' AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'hyperevm' AS source
                    FROM hyperevmHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "robinhood" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'robinhood' AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'robinhood' AS source
                    FROM robinhoodHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            if let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "arc" {
                if let balance = try BalanceRecord.fetchOne(db, sql: """
                    SELECT accountID,assetID,'arc' AS networkID,amountAtomic,observedAt,checkpoint AS blockHeight,'arc' AS source
                    FROM arcHoldings WHERE accountID=? AND assetID=?
                    """, arguments: [accountID,assetID]) { return balance }
            }
            return try BalanceRecord.fetchOne(db, key: ["accountID": accountID, "assetID": assetID])
        }
    }
    public func savePrices(_ prices: [PriceRecord]) async throws {
        guard prices.count <= 2_000 else { throw StoreError.invalidValue("price batch") }
        try await pool.write { db in
            for price in prices {
                // Every market provider supplies USD quotes. Display currency
                // changes use the shared FX table, never per-currency prices.
                guard price.currency == "USD" else { throw StoreError.invalidValue("market price must be USD") }
                try Validation.price(price.value)
                guard price.observedAt.isFinite else { throw StoreError.invalidValue("price timestamp") }
                try price.upsert(db)
            }
        }
    }
    public func latestPrice(assetID: String, currency: String) async throws -> PriceRecord? {
        try await pool.read { db in
            try PriceRecord.fetchOne(db, sql: "SELECT * FROM prices WHERE assetID=? AND currency=? ORDER BY observedAt DESC LIMIT 1",
                                     arguments: [assetID, currency])
        }
    }
    public func priceHistory(assetID: String, currency: String, before: Double? = nil, limit: Int = 100) async throws -> [PriceRecord] {
        try await pool.read { db in
            try PriceRecord.fetchAll(db, sql: "SELECT * FROM prices WHERE assetID=? AND currency=? AND observedAt < ? ORDER BY observedAt DESC LIMIT ?",
                                     arguments: [assetID, currency, before ?? Double.greatestFiniteMagnitude, Self.pageSize(limit)])
        }
    }
    public func transaction(_ id: String) async throws -> TransactionRecord? {
        try await pool.read { try TransactionRecord.fetchOne($0, key: id) }
    }
    public func transfers(transactionID: String) async throws -> [TransferRecord] {
        try await pool.read { try TransferRecord.fetchAll($0, sql: "SELECT * FROM transfers WHERE transactionID=? ORDER BY eventIndex", arguments: [transactionID]) }
    }
    public func history(walletID: String, before: HistoryCursor? = nil, limit: Int = 50) async throws -> [HistoryEntry] {
        try await pool.read { try Self.history($0, walletID: walletID, before: before, limit: limit) }
    }
    static func history(_ db: Database, walletID: String, before: HistoryCursor?, limit: Int) throws -> [HistoryEntry] {
        var sql = """
            SELECT a.id,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,
                   a.amountAtomic,a.counterparty,a.sortTimestamp AS timestamp,COALESCE(e.outcome,t.state) AS state,t.hash
            FROM visibleActivity a JOIN transactions t ON t.id=a.transactionID JOIN walletAccounts ownerAccount ON ownerAccount.id=a.accountID
                LEFT JOIN transactionEvidence e ON e.accountID=a.accountID AND e.transactionID=a.transactionID WHERE a.walletID=?
            AND (a.networkID<>'solana' OR EXISTS (SELECT 1 FROM solanaActivity sa WHERE sa.activityID=a.id
                AND sa.owner=COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=a.accountID AND isSelected=1),ownerAccount.address)))
            """
        var args: StatementArguments = [walletID]
        if let before { sql += " AND (a.sortTimestamp,a.id) < (?,?)"; args += [before.timestamp, before.id] }
        sql += " ORDER BY a.sortTimestamp DESC,a.id DESC LIMIT ?"; args += [pageSize(limit)]
        return try HistoryEntry.fetchAll(db, sql: sql, arguments: args).map { try Self.projectSelfTransferFee($0, db: db) }
    }
    public func observeHistory(walletID: String, limit: Int = 50) -> AsyncThrowingStream<[HistoryEntry], Error> {
        stream { try Self.history($0, walletID: walletID, before: nil, limit: limit) }
    }
    public func cursor(accountID: String, stream: String) async throws -> SyncCursor? {
        try await pool.read { try SyncCursor.fetchOne($0, key: ["accountID": accountID, "stream": stream]) }
    }
    public func spendableOutputs(accountID: String, after: OutputCursor? = nil, limit: Int = 200) async throws -> [UTXORecord] {
        try await pool.read { db in
            // Registered discovery accounts must use the same verified policy
            // as wallet-wide coin selection, including CashToken protection,
            // mining maturity and freshness. This older paging API must not
            // become a way around those checks for a future Send screen.
            if let account = try AccountRecord.fetchOne(db, key: accountID),
               let network = UTXONetwork(rawValue: account.networkID),
               try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM bitcoinWallets WHERE accountID=?)", arguments: [accountID]) == true {
                let outputs = try Self.bitcoinSpendableOutputs(walletID: account.walletID, now: .now, network: network, accountID: accountID, db: db).map(\.output)
                return Array(outputs.filter { output in
                    guard let after else { return true }
                    return (output.value, output.transactionHash, output.outputIndex) > (after.value, after.hash, after.index)
                }.sorted { ($0.value, $0.transactionHash, $0.outputIndex) < ($1.value, $1.transactionHash, $1.outputIndex) }
                    .prefix(Self.pageSize(limit)))
            }
            var sql = """
                SELECT u.*,o.accountID FROM accountUTXOs o JOIN utxos u USING(networkID,transactionHash,outputIndex)
                WHERE o.accountID=? AND u.spent=0 AND u.reservedBy IS NULL
                """
            var args: StatementArguments = [accountID]
            if let after {
                sql += " AND (u.value,u.transactionHash,u.outputIndex) > (?,?,?)"
                args += [after.value, after.hash, after.index]
            }
            sql += " ORDER BY u.value,u.transactionHash,u.outputIndex LIMIT ?"
            args += [Self.pageSize(limit)]
            return try UTXORecord.fetchAll(db, sql: sql, arguments: args)
        }
    }

    /// Invalidate derived chain state atomically; retain history as reorged and
    /// signed/broadcast send reservations until the provider reconciles them.
    public func invalidate(networkID: String, fromBlock: Int64) async throws {
        guard fromBlock >= 0 else { throw StoreError.invalidValue("reorg height") }
        try await pool.write { db in
            try db.execute(sql: "UPDATE walletAccounts SET syncGeneration=syncGeneration+1 WHERE networkID=?", arguments: [networkID])
            try db.execute(sql: "UPDATE transactions SET state='reorged',blockHeight=NULL,blockHash=NULL WHERE networkID=? AND blockHeight>=?", arguments: [networkID, fromBlock])
            try db.execute(sql: "DELETE FROM balances WHERE networkID=? AND (blockHeight IS NULL OR blockHeight>=?)", arguments: [networkID, fromBlock])
            try db.execute(sql: "UPDATE utxos SET blockHeight=NULL,spent=1 WHERE networkID=? AND blockHeight>=?", arguments: [networkID, fromBlock])
            try db.execute(sql: "DELETE FROM syncCursors WHERE accountID IN (SELECT id FROM walletAccounts WHERE networkID=?)", arguments: [networkID])
        }
    }
    static func pageSize(_ requested: Int) -> Int { min(200, max(1, requested)) }
}
