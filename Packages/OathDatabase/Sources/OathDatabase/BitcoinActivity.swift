import Foundation
import GRDB
import OathBitcoin

/// Hydrates public history independently from UTXO discovery. A history-server
/// failure must never discard the last successfully verified balance or rows.
public struct BitcoinActivitySynchronizer: Sendable {
    public let database: OathDatabase
    public let client: ElectrumPool
    public init(database: OathDatabase, client: ElectrumPool) { self.database = database; self.client = client }

    public func refresh(accountID: String) async throws {
        guard let state = try await database.bitcoinState(accountID: accountID),
              let account = try await database.account(accountID) else { throw StoreError.missingRecord }
        let network = state.descriptor.network
        let pending = try await database.bitcoinActivityWork(account: account)
        for start in stride(from: 0, to: pending.count, by: 40) {
            try Task.checkCancellation()
            let page = Array(pending[start..<min(start + 40, pending.count)])
            let ids = Set(page.map(\.txid))
            var raw = try await cached(accountID: accountID, ids: ids)
            raw.merge(try await client.transactions(txids: Array(ids.subtracting(raw.keys)))) { _, new in new }
            var decoded: [String: BitcoinTransactions.Details] = [:]
            for (id, data) in raw { decoded[id] = try BitcoinTransactions.details(data, network: network) }
            let parents = Set(decoded.values.flatMap { $0.inputs.map(\.txid) }).subtracting(raw.keys)
            let savedParents = try await cached(accountID: accountID, ids: parents)
            raw.merge(savedParents) { old, _ in old }
            async let fetchedParents = client.transactions(txids: Array(parents.subtracting(savedParents.keys)))
            async let blockTimes = client.blockTimes(heights: Array(Set(page.map(\.height).filter { $0 > 0 })))
            let (fetched, times) = try await (fetchedParents, blockTimes)
            raw.merge(fetched) { _, new in new }
            try Task.checkCancellation()
            try await database.commitBitcoinActivity(account: account, page: page, raw: raw, times: times)
        }
        // Keep disappeared transactions, but never label them cancelled merely
        // because one Electrum peer no longer reports them.
        try await database.pool.write { db in
            guard try AccountRecord.fetchOne(db, key: accountID)?.syncGeneration == account.syncGeneration else { throw StoreError.staleSync }
            try db.execute(sql: """
                UPDATE transactions SET state='reorged' WHERE networkID=? AND id IN
                (SELECT transactionID FROM activity WHERE accountID=?)
                AND NOT EXISTS(SELECT 1 FROM bitcoinHistory h WHERE h.accountID=? AND h.txid=transactions.hash)
                """, arguments: [network.rawValue, accountID, accountID])
        }
    }
    private func cached(accountID: String, ids: Set<String>) async throws -> [String: Data] {
        guard !ids.isEmpty else { return [:] }
        return try await database.pool.read { db in
            var result: [String: Data] = [:]
            // Keep SQLite's parameter budget bounded, even for consolidation transactions.
            for id in ids {
                if let data = try Data.fetchOne(db, sql: "SELECT raw FROM bitcoinTransactions WHERE accountID=? AND txid=?", arguments: [accountID, id]) { result[id] = data }
            }
            return result
        }
    }
}

extension OathDatabase {
    func bitcoinActivityWork(account: AccountRecord) async throws -> [BitcoinHistoryItem] {
        try await pool.read { db in
            // Transaction bodies are global, but ownership/amount projections are
            // per account. Another wallet's cached transaction cannot skip ours.
            try Row.fetchAll(db, sql: """
                SELECT h.txid,h.height FROM bitcoinHistory h
                LEFT JOIN transactions t ON t.id=? || ':' || h.txid
                WHERE h.accountID=? AND NOT (
                    h.height>0 AND COALESCE(t.state='confirmed',0)
                    AND COALESCE(t.blockHeight=h.height,0) AND t.feeAtomic IS NOT NULL
                    AND EXISTS(SELECT 1 FROM activity a WHERE a.accountID=h.accountID AND a.transactionID=t.id))
                ORDER BY h.height<=0 DESC,h.height DESC
                """, arguments: [account.networkID, account.id]).map { .init(txid: $0["txid"], height: $0["height"]) }
        }
    }
    func commitBitcoinActivity(account: AccountRecord, page: [BitcoinHistoryItem], raw: [String: Data], times: [Int64: Double]) async throws {
        guard let network = UTXONetwork(rawValue: account.networkID) else { throw StoreError.invalidValue("network") }
        let decoded = try raw.mapValues { try BitcoinTransactions.details($0, network: network) }
        guard decoded.allSatisfy({ $0.key == $0.value.txid }) else { throw BitcoinError.invalidResponse }
        try await pool.write { db in
            guard try AccountRecord.fetchOne(db, key: account.id)?.syncGeneration == account.syncGeneration,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')") != true else { throw StoreError.staleSync }
            let ownScripts = Set(try String.fetchAll(db, sql: "SELECT script FROM bitcoinAddresses WHERE accountID=?", arguments: [account.id]))
            func sum(_ values: [Int64]) throws -> Int64 {
                try values.reduce(0) { a, b in
                    let result = a.addingReportingOverflow(b)
                    guard !result.overflow else { throw BitcoinError.invalidResponse }; return result.partialValue
                }
            }
            for item in page {
                guard let tx = decoded[item.txid],
                      try Int64.fetchOne(db, sql: "SELECT height FROM bitcoinHistory WHERE accountID=? AND txid=?", arguments: [account.id, item.txid]) == item.height else { throw StoreError.staleSync }
                let inputs = try tx.inputs.map { input -> BitcoinTransactions.Output in
                    guard let previous = decoded[input.txid], previous.outputs.indices.contains(input.index) else { throw BitcoinError.invalidResponse }
                    return previous.outputs[input.index]
                }
                let spent = try sum(inputs.filter { ownScripts.contains($0.script) }.map(\.value))
                let received = try sum(tx.outputs.filter { ownScripts.contains($0.script) }.map(\.value))
                let allOwned = !inputs.isEmpty && inputs.allSatisfy { ownScripts.contains($0.script) }
                let allReturned = allOwned && tx.outputs.allSatisfy { ownScripts.contains($0.script) }
                let fee = tx.coinbase ? 0 : try sum(inputs.map(\.value)) - sum(tx.outputs.map(\.value))
                guard fee >= 0 else { throw BitcoinError.invalidResponse }
                let direction = allReturned ? "self" : spent > received ? "outgoing" : received > spent ? "incoming" : "self"
                let amount = direction == "outgoing" ? spent - received - (allOwned ? fee : 0) : direction == "incoming" ? received - spent : received
                guard amount >= 0 else { throw BitcoinError.invalidResponse }
                let id = account.networkID + ":" + item.txid
                let previous = try TransactionRecord.fetchOne(db, key: id)
                let timestamp = item.height > 0 ? times[item.height] : previous?.timestamp ?? Date().timeIntervalSince1970
                guard let timestamp, timestamp > 0 else { throw BitcoinError.invalidResponse }
                let record = TransactionRecord(id: id, networkID: account.networkID, hash: item.txid,
                    state: item.height > 0 ? "confirmed" : "pending", blockHeight: item.height > 0 ? item.height : nil,
                    timestamp: timestamp, feeAtomic: String(fee), updatedAt: Date().timeIntervalSince1970)
                try record.upsert(db)
                let destinations = direction == "incoming" ? inputs : tx.outputs.filter { !ownScripts.contains($0.script) }
                let addresses = Array(Set(destinations.compactMap(\.address))).sorted()
                // A single counterparty is shown only when it is unambiguous.
                let counterparty = addresses.count == 1 ? addresses[0] : ""
                try ActivityRecord(id: account.id + ":" + id, walletID: account.walletID, accountID: account.id,
                    networkID: account.networkID, transactionID: id, assetID: account.networkID + ":native",
                    direction: direction, amountAtomic: String(amount), counterparty: counterparty, timestamp: timestamp).upsert(db)
                try Self.saveBitcoinParticipants(db, accountID: account.id, transactionID: id,
                    addresses: Set((inputs + tx.outputs).compactMap(\.address)))
                for (index, output) in tx.outputs.enumerated() {
                    try TransferRecord(id: id + ":" + String(index), transactionID: id, networkID: account.networkID,
                        assetID: account.networkID + ":native", eventIndex: index,
                        fromAddress: inputs.count == 1 ? inputs[0].address ?? "" : "", toAddress: output.address ?? "",
                        amountAtomic: String(output.value)).upsert(db)
                }
                try Self.saveTransactionEvidence(accountID: account.id, tx: record,
                    keys: Set(tx.inputs.map(\.outpoint)), returnsToWallet: allReturned, db: db)
            }
            for (id, data) in raw {
                try db.execute(sql: "INSERT OR IGNORE INTO bitcoinTransactions(accountID,txid,raw) VALUES(?,?,?)", arguments: [account.id, id, data])
            }
        }
    }

    /// Older projections encoded nonstandard scripts and two MWEB markers as transparent
    /// addresses. Their lowercase Bech32 version and length uniquely identify the affected
    /// shapes. Qualify all repairs by chain, including the account-scoped search index.
    static func clearInvalidLitecoinHistoryAddresses(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TEMP TABLE invalidLitecoinHistoryAddress (value TEXT PRIMARY KEY) WITHOUT ROWID;
            INSERT INTO invalidLitecoinHistoryAddress
            SELECT value FROM (
                SELECT counterparty AS value FROM activity WHERE networkID='litecoin'
                UNION SELECT fromAddress FROM transfers WHERE networkID='litecoin'
                UNION SELECT toAddress FROM transfers WHERE networkID='litecoin'
                UNION SELECT p.address FROM transactionParticipants p
                    JOIN accounts a ON a.id=p.accountID WHERE a.networkID='litecoin'
            ) WHERE value GLOB 'ltc1*' AND (
                length(value)>75 OR
                (value GLOB 'ltc1q*' AND length(value) NOT IN (43,63)) OR
                (value GLOB 'ltc1[gf]*' AND length(value)=63)
            );
            UPDATE activity SET counterparty='' WHERE networkID='litecoin' AND counterparty IN invalidLitecoinHistoryAddress;
            UPDATE transfers SET fromAddress='' WHERE networkID='litecoin' AND fromAddress IN invalidLitecoinHistoryAddress;
            UPDATE transfers SET toAddress='' WHERE networkID='litecoin' AND toAddress IN invalidLitecoinHistoryAddress;
            DELETE FROM transactionParticipants WHERE accountID IN (SELECT id FROM accounts WHERE networkID='litecoin')
                AND address IN invalidLitecoinHistoryAddress;
            DROP TABLE invalidLitecoinHistoryAddress;
            """)
    }

    static func saveBitcoinParticipants(_ db: Database, accountID: String, transactionID: String,
                                       addresses: Set<String>) throws {
        for address in addresses where !address.isEmpty {
            try db.execute(sql: "INSERT OR IGNORE INTO transactionParticipants(accountID,transactionID,address) VALUES(?,?,?)",
                           arguments: [accountID, transactionID, address])
        }
    }

    /// Existing cached transactions are searchable offline immediately after the
    /// upgrade. Resolve inputs against cached parents; never invent a sender for
    /// a missing/undecodable previous output. Migration runs off the main actor.
    static func backfillBitcoinParticipants(_ db: Database) throws {
        let cursor = try Row.fetchCursor(db, sql: """
            SELECT DISTINCT a.accountID,a.transactionID,a.networkID,b.raw
            FROM activity a JOIN transactions t ON t.id=a.transactionID
            JOIN bitcoinTransactions b ON b.accountID=a.accountID AND b.txid=t.hash
            """)
        while let row = try cursor.next() {
            let accountID: String = row["accountID"], transactionID: String = row["transactionID"]
            guard let network = UTXONetwork(rawValue: row["networkID"]),
                  let tx = try? BitcoinTransactions.details(row["raw"], network: network) else { continue }
            var addresses = Set(tx.outputs.compactMap(\.address))
            for input in tx.inputs {
                guard let raw = try Data.fetchOne(db, sql: "SELECT raw FROM bitcoinTransactions WHERE accountID=? AND txid=?",
                                                 arguments: [accountID, input.txid]),
                      let parent = try? BitcoinTransactions.details(raw, network: network),
                      parent.outputs.indices.contains(input.index),
                      let address = parent.outputs[input.index].address else { continue }
                addresses.insert(address)
            }
            try saveBitcoinParticipants(db, accountID: accountID, transactionID: transactionID, addresses: addresses)
        }
    }
}
