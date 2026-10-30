import Foundation
import GRDB
import OathBitcoin

public struct Outpoint: Hashable, Sendable {
    public let hash: String
    public let index: Int
    public init(hash: String, index: Int) { self.hash = hash; self.index = index }
}

extension OathDatabase {
    public func saveDraft(_ send: SendRecord) async throws {
        try Validation.amount(send.amountAtomic)
        guard send.state == "draft", send.nonce == nil, send.signedPayload == nil, send.transactionID == nil,
              !send.recipient.isEmpty, !send.idempotencyKey.isEmpty,
              send.createdAt.isFinite, send.updatedAt.isFinite else { throw StoreError.invalidValue("send draft") }
        try await pool.write { db in
            guard let wallet = try WalletRecord.fetchOne(db, key: send.walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
            guard wallet.kind != "watchOnly" else { throw StoreError.readOnlyWallet }
            guard let account = try AccountRecord.fetchOne(db, key: send.accountID),
                  account.walletID == send.walletID, account.networkID == send.networkID,
                  let network = try NetworkRecord.fetchOne(db, key: send.networkID) else { throw StoreError.conflictingIdentity }
            var send = send
            send.senderAddress = network.family == "evm" ? account.address.lowercased() : account.address
            if let existing = try SendRecord.fetchOne(db, key: send.id) {
                guard existing.state == "draft", existing.accountID == send.accountID,
                      existing.walletID == send.walletID, existing.networkID == send.networkID,
                      existing.idempotencyKey == send.idempotencyKey else { throw StoreError.invalidTransition }
                try send.update(db)
            } else { try send.insert(db) }
        }
    }

    /// Compare-and-reserve all inputs in the same writer transaction. Two send
    /// tasks racing for an output cannot both acquire it, even after restart.
    public func queueSend(_ id: String, outputs: [Outpoint] = [], networkNonce: UInt64? = nil) async throws -> SendRecord {
        guard Set(outputs).count == outputs.count, outputs.count <= 1000 else { throw StoreError.invalidValue("outputs") }
        return try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db, key: id) else { throw StoreError.missingRecord }
            guard send.state == "draft",
                  let wallet = try WalletRecord.fetchOne(db, key: send.walletID), wallet.deletedAt == nil else { throw StoreError.invalidTransition }
            guard let network = try NetworkRecord.fetchOne(db, key: send.networkID) else { throw StoreError.missingRecord }
            guard (network.family == "utxo") == !outputs.isEmpty,
                  (network.family == "evm") == (networkNonce != nil) else { throw StoreError.invalidValue("spending reservation") }
            if let networkNonce {
                let reserved = try String.fetchAll(db, sql: "SELECT nonce FROM sends WHERE networkID=? AND senderAddress=? AND nonce IS NOT NULL AND state IN ('queued','signed','broadcast')", arguments: [send.networkID, send.senderAddress])
                var nonce = networkNonce
                for value in reserved {
                    guard let existing = UInt64(value) else { throw StoreError.invalidValue("stored nonce") }
                    if existing >= nonce {
                        guard existing < UInt64.max else { throw StoreError.reservationConflict }
                        nonce = existing + 1
                    }
                }
                send.nonce = String(nonce)
            }
            let trackedBitcoin = try UTXONetwork(rawValue: send.networkID) != nil && (Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM bitcoinWallets w JOIN accounts a ON a.id=w.accountID WHERE a.walletID=? AND a.networkID=?)",
                arguments: [send.walletID, send.networkID]) == true)
            if trackedBitcoin {
                let available = Set(try Self.bitcoinSpendableOutputs(walletID: send.walletID, now: .now, network: UTXONetwork(rawValue: send.networkID)!, db: db)
                    .map { Outpoint(hash: $0.output.transactionHash, index: $0.output.outputIndex) })
                guard Set(outputs).isSubset(of: available) else { throw StoreError.reservationConflict }
            }
            for output in outputs {
                try db.execute(sql: """
                    UPDATE utxos SET reservedBy=? WHERE networkID=? AND transactionHash=? AND outputIndex=?
                    AND spent=0 AND reservedBy IS NULL AND EXISTS (
                        SELECT 1 FROM accountUTXOs o JOIN accounts a ON a.id=o.accountID
                        WHERE (o.accountID=? OR (?=1 AND a.walletID=?)) AND o.networkID=utxos.networkID
                        AND o.transactionHash=utxos.transactionHash AND o.outputIndex=utxos.outputIndex
                    )
                    """, arguments: [send.id, send.networkID, output.hash, output.index, send.accountID, trackedBitcoin, send.walletID])
                guard db.changesCount == 1 else { throw StoreError.reservationConflict }
            }
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
            return send
        }
    }

    /// Signed transactions are broadcastable data, never a seed/private key.
    /// A network timeout leaves the operation broadcast/pending for reconciliation;
    /// it must not release inputs or recycle its nonce as if it never happened.
    public func transitionSend(_ id: String, from expected: String, to next: String,
                               signedPayload: Data? = nil, transactionID: String? = nil,
                               failureCode: String? = nil) async throws -> SendRecord {
        let transitions: [String: Set<String>] = [
            "draft": ["cancelled"], "queued": ["signed", "failed", "cancelled"],
            "signed": ["broadcast"], "broadcast": ["confirmed", "failed"]
        ]
        guard transitions[expected]?.contains(next) == true else { throw StoreError.invalidTransition }
        return try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db, key: id), send.state == expected else { throw StoreError.invalidTransition }
            if next == "signed" {
                guard let signedPayload, !signedPayload.isEmpty, signedPayload.count <= 1_000_000 else {
                    throw StoreError.invalidValue("signed transaction")
                }
                send.signedPayload = signedPayload
            } else if signedPayload != nil { throw StoreError.invalidTransition }
            if let transactionID { send.transactionID = transactionID }
            if next == "confirmed" {
                guard let txID = send.transactionID,
                      let tx = try TransactionRecord.fetchOne(db, key: txID), tx.state == "confirmed" else { throw StoreError.invalidTransition }
            }
            if expected == "broadcast", next == "failed" {
                guard let txID = send.transactionID,
                      let tx = try TransactionRecord.fetchOne(db, key: txID) else { throw StoreError.invalidTransition }
                let minedBitcoinConflict = try ["bitcoin", "bitcoincash", "litecoin", "dogecoin"].contains(send.networkID) && Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM transactionEvidence e
                    JOIN accounts a ON a.id=e.accountID
                    JOIN transactions winner ON winner.networkID=? AND winner.hash=e.replacementHash
                    WHERE a.walletID=? AND e.transactionID=? AND e.outcome IN ('replaced','canceled')
                    AND winner.state='confirmed' AND winner.blockHeight>0)
                    """, arguments: [send.networkID, send.walletID, txID]) == true
                guard ["failed","replaced"].contains(tx.state) || minedBitcoinConflict else { throw StoreError.invalidTransition }
            }
            send.state = next; send.failureCode = failureCode; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
            // Every chain using the shared send journal gets a durable refresh
            // intent before submission can escape the process. No network work
            // or callback runs inside this database transaction.
            if next == "broadcast" || next == "confirmed" {
                try db.execute(sql: "INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)", arguments: [id])
            }
            if next == "confirmed" {
                try db.execute(sql: "UPDATE utxos SET spent=1,reservedBy=NULL WHERE reservedBy=?", arguments: [id])
            } else if next == "cancelled" || next == "failed" {
                try db.execute(sql: "UPDATE utxos SET reservedBy=NULL WHERE reservedBy=?", arguments: [id])
            }
            return send
        }
    }
    public func send(_ id: String) async throws -> SendRecord? {
        try await pool.read { try SendRecord.fetchOne($0, key: id) }
    }
    public func sends(walletID: String, before: RecordPageCursor? = nil, limit: Int = 50) async throws -> [SendRecord] {
        try await pool.read { db in
            var sql = "SELECT * FROM sends WHERE walletID=?"
            var args: StatementArguments = [walletID]
            if let before { sql += " AND (createdAt,id)<(?,?)"; args += [before.timestamp, before.id] }
            sql += " ORDER BY createdAt DESC,id DESC LIMIT ?"; args += [Self.pageSize(limit)]
            return try SendRecord.fetchAll(db, sql: sql, arguments: args)
        }
    }
    public func pendingSends(after: RecordPageCursor? = nil, limit: Int = 100) async throws -> [SendRecord] {
        try await pool.read { db in
            // Immutable ordering keeps pagination stable as recovery updates
            // states/timestamps. Old pending transfers cannot starve newer ones.
            var sql = "SELECT * FROM sends WHERE state IN ('queued','signed','broadcast')"
            var arguments: StatementArguments = []
            if let after { sql += " AND (createdAt,id)>(?,?)"; arguments += [after.timestamp, after.id] }
            sql += " ORDER BY createdAt,id LIMIT ?"; arguments += [Self.pageSize(limit)]
            return try SendRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }
    public func reservedOutputs(sendID: String) async throws -> [UTXORecord] {
        try await pool.read { db in
            try UTXORecord.fetchAll(db, sql: """
                SELECT u.*,MIN(o.accountID) AS accountID FROM utxos u JOIN sends s ON s.id=u.reservedBy
                JOIN accountUTXOs o ON o.networkID=u.networkID AND o.transactionHash=u.transactionHash AND o.outputIndex=u.outputIndex
                JOIN accounts a ON a.id=o.accountID AND a.walletID=s.walletID WHERE s.id=?
                GROUP BY u.networkID,u.transactionHash,u.outputIndex
                """, arguments: [sendID])
        }
    }
    public func saveReceive(_ request: ReceiveRecord) async throws {
        if let amount = request.amountAtomic { try Validation.amount(amount) }
        guard request.createdAt.isFinite, request.expiresAt?.isFinite != false,
              (request.memo?.count ?? 0) <= 20_000 else { throw StoreError.invalidValue("receive request") }
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: request.accountID),
                  request.networkID == account.networkID else { throw StoreError.conflictingIdentity }
            let derivedBitcoin = try UTXONetwork(rawValue: request.networkID) != nil && (Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM bitcoinAddresses WHERE accountID=? AND address=? AND issued=1)",
                arguments: [request.accountID, request.address]) == true)
            let derivedSolana = try request.networkID == "solana" && (Bool.fetchOne(db,
                sql: "SELECT EXISTS(SELECT 1 FROM solanaReceiveAddresses WHERE accountID=? AND address=?)",
                arguments: [request.accountID, request.address]) == true)
            guard request.address == account.address || derivedBitcoin || derivedSolana else { throw StoreError.conflictingIdentity }
            if let old = try ReceiveRecord.fetchOne(db, key: request.id) {
                guard old.accountID == request.accountID, old.assetID == request.assetID,
                      old.createdAt == request.createdAt else { throw StoreError.conflictingIdentity }
                try request.update(db)
            } else { try request.insert(db) }
        }
    }
    public func receives(accountID: String, before: RecordPageCursor? = nil, limit: Int = 100) async throws -> [ReceiveRecord] {
        try await pool.read { db in
            var sql = "SELECT * FROM receives WHERE accountID=?"
            var args: StatementArguments = [accountID]
            if let before { sql += " AND (createdAt,id)<(?,?)"; args += [before.timestamp, before.id] }
            sql += " ORDER BY createdAt DESC,id DESC LIMIT ?"; args += [Self.pageSize(limit)]
            return try ReceiveRecord.fetchAll(db, sql: sql, arguments: args)
        }
    }

    public func saveNote(_ note: NoteRecord) async throws {
        guard note.body.count <= 20_000, note.updatedAt.isFinite else { throw StoreError.invalidValue("note") }
        try await pool.write { db in
            try Self.validateSubject(db, walletID: note.walletID, type: note.subjectType, id: note.subjectID)
            if let old = try NoteRecord.fetchOne(db, key: note.id) {
                guard old.walletID == note.walletID, old.subjectType == note.subjectType, old.subjectID == note.subjectID else { throw StoreError.conflictingIdentity }
            }
            try note.upsert(db)
        }
    }
    public func notes(walletID: String, before: RecordPageCursor? = nil, limit: Int = 100) async throws -> [NoteRecord] {
        try await pool.read { db in
            var sql = "SELECT * FROM notes WHERE walletID=?"
            var args: StatementArguments = [walletID]
            if let before { sql += " AND (updatedAt,id)<(?,?)"; args += [before.timestamp, before.id] }
            sql += " ORDER BY updatedAt DESC,id DESC LIMIT ?"; args += [Self.pageSize(limit)]
            return try NoteRecord.fetchAll(db, sql: sql, arguments: args)
        }
    }
    public func searchNotes(walletID: String, query: String, limit: Int = 50) async throws -> [NoteRecord] {
        let words = query.split(whereSeparator: \.isWhitespace).prefix(12)
        guard !words.isEmpty else { return try await notes(walletID: walletID, limit: limit) }
        let match = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        return try await pool.read { try NoteRecord.fetchAll($0, sql: """
            SELECT * FROM notes WHERE walletID=? AND rowid IN (SELECT rowid FROM notesSearch WHERE notesSearch MATCH ?)
            ORDER BY updatedAt DESC,id DESC LIMIT ?
            """, arguments: [walletID, match, Self.pageSize(limit)]) }
    }
    public func deleteNote(_ id: String, walletID: String) async throws {
        try await pool.write { try $0.execute(sql: "DELETE FROM notes WHERE id=? AND walletID=?", arguments: [id, walletID]) }
    }
    public func saveLabel(_ label: LabelRecord) async throws {
        guard !label.name.isEmpty, label.name.count <= 100, label.updatedAt.isFinite else { throw StoreError.invalidValue("label") }
        try await pool.write { db in
            if let old = try LabelRecord.fetchOne(db, key: label.id), old.walletID != label.walletID { throw StoreError.conflictingIdentity }
            try label.upsert(db)
        }
    }
    public func labels(walletID: String) async throws -> [LabelRecord] {
        try await pool.read { try LabelRecord.fetchAll($0, sql: "SELECT * FROM labels WHERE walletID=? ORDER BY name", arguments: [walletID]) }
    }
    public func assignLabel(_ assignment: LabelAssignment) async throws {
        try await pool.write { db in
            try Self.validateSubject(db, walletID: assignment.walletID, type: assignment.subjectType, id: assignment.subjectID)
            try assignment.insert(db, onConflict: .ignore)
        }
    }
    public func labels(walletID: String, subjectType: String, subjectID: String) async throws -> [LabelRecord] {
        try await pool.read { try LabelRecord.fetchAll($0, sql: """
            SELECT l.* FROM labelAssignments a JOIN labels l ON l.id=a.labelID
            WHERE a.walletID=? AND a.subjectType=? AND a.subjectID=? ORDER BY l.name
            """, arguments: [walletID, subjectType, subjectID]) }
    }
    public func removeLabel(_ id: String, walletID: String) async throws {
        try await pool.write { try $0.execute(sql: "DELETE FROM labels WHERE id=? AND walletID=?", arguments: [id, walletID]) }
    }
    public func unassignLabel(_ assignment: LabelAssignment) async throws {
        try await pool.write { try $0.execute(sql: "DELETE FROM labelAssignments WHERE labelID=? AND walletID=? AND subjectType=? AND subjectID=?",
                                             arguments: [assignment.labelID, assignment.walletID, assignment.subjectType, assignment.subjectID]) }
    }
    private static func validateSubject(_ db: Database, walletID: String, type: String, id: String) throws {
        let sql: String
        switch type {
        case "wallet": sql = "SELECT 1 FROM wallets WHERE id=? AND id=?"
        case "account": sql = "SELECT 1 FROM accounts WHERE id=? AND walletID=?"
        case "transaction": sql = "SELECT 1 FROM activity WHERE transactionID=? AND walletID=? LIMIT 1"
        case "activity": sql = "SELECT 1 FROM activity WHERE id=? AND walletID=?"
        case "send": sql = "SELECT 1 FROM sends WHERE id=? AND walletID=?"
        case "receive": sql = "SELECT 1 FROM receives r JOIN accounts a ON a.id=r.accountID WHERE r.id=? AND a.walletID=?"
        default: throw StoreError.invalidValue("note subject")
        }
        guard try Int.fetchOne(db, sql: sql, arguments: [id, walletID]) != nil else { throw StoreError.conflictingIdentity }
    }
}
