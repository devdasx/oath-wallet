import Foundation
import GRDB
import OathAnkr

public struct SolanaSyncTicket: Sendable {
    public let account: AccountRecord
    public let owner: String
    public let runID: String
}
public struct SolanaHistoryCursor: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "solanaHistoryCursors"
    public let accountID: String
    public let owner: String
    public let address: String
    public var head: String?
    public var before: String?
    public var complete: Bool
    public var pendingBefore: String?
    public var pendingHead: String?
    public var lastChecked: Double
    public var priority: Int
}

extension OathDatabase {
    public func account(_ id: String) async throws -> AccountRecord? {
        try await pool.read { try AccountRecord.fetchOne($0, key: id) }
    }

    static func solanaOwner(_ account: AccountRecord, db: Database) throws -> String {
        try String.fetchOne(db, sql: "SELECT address FROM solanaReceiveAddresses WHERE accountID=? AND isSelected=1", arguments: [account.id]) ?? account.address
    }
    public func beginSolanaSync(accountID: String) async throws -> SolanaSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "solana" else { throw StoreError.missingRecord }
            let owner = try Self.solanaOwner(account, db: db)
            guard SolanaIdentity.isAddress(owner) else { throw SolanaError.invalidAddress }
            let run = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO solanaSync(accountID,owner,runID) VALUES(?,?,?)
                ON CONFLICT(accountID,owner) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL
                """, arguments: [accountID,owner,run])
            try Self.watchSolana(owner, priority: 0, accountID: accountID, owner: owner, db: db)
            return .init(account: account, owner: owner, runID: run)
        }
    }
    static func validateSolana(_ ticket: SolanaSyncTicket, db: Database) throws {
        guard let account = try AccountRecord.fetchOne(db, key: ticket.account.id), account.networkID == "solana",
              account.syncGeneration == ticket.account.syncGeneration, try Self.solanaOwner(account, db: db) == ticket.owner,
              try String.fetchOne(db, sql: "SELECT runID FROM solanaSync WHERE accountID=? AND owner=?", arguments: [account.id,ticket.owner]) == ticket.runID else {
            throw StoreError.staleSync
        }
    }
    public func failSolanaSync(_ ticket: SolanaSyncTicket, history: Bool, code: String = "unavailable") async throws {
        try await pool.write { db in
            try Self.validateSolana(ticket, db: db)
            try db.execute(sql: "UPDATE solanaSync SET \(history ? "historyFailure" : "failure")=? WHERE accountID=? AND owner=?",
                arguments: [String(code.prefix(100)),ticket.account.id,ticket.owner])
        }
    }
    public func solanaInventory(accountID: String) async throws -> SolanaInventory? {
        try await pool.read { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID),
                  let data = try Data.fetchOne(db, sql: "SELECT inventory FROM solanaSync WHERE accountID=? AND owner=?",
                    arguments: [accountID, Self.solanaOwner(account, db: db)]) else { return nil }
            return try JSONDecoder().decode(SolanaInventory.self, from: data)
        }
    }
    static func solanaAsset(mint: String, decimals: Int, info: SolanaTokenInfo?, db: Database) throws -> AssetRecord {
        if mint == "native" {
            guard let native = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID='solana' AND reference='native'") else { throw StoreError.missingRecord }
            return native
        }
        guard SolanaIdentity.isAddress(mint), (0...255).contains(decimals), info == nil || (info?.address == mint && info?.decimals == decimals) else { throw SolanaError.malformed }
        if let info {
            try HistorySafety.trust(networkID: "solana", reference: mint, decimals: info.decimals,
                source: "verified.history.catalog", observedAt: Date().timeIntervalSince1970, db: db)
        }
        if var existing = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID='solana' AND reference=?", arguments: [mint]) {
            guard existing.decimals == decimals else { throw StoreError.conflictingIdentity }
            if let info { existing.name = info.name; existing.symbol = info.symbol; existing.logo = info.logo ?? existing.logo; try existing.update(db) }
            return existing
        }
        let asset = AssetRecord(id: "solana:" + mint, networkID: "solana", reference: mint,
            name: info?.name ?? String(mint.prefix(6)) + "…" + String(mint.suffix(4)), symbol: info?.symbol ?? "SPL",
            decimals: decimals, logo: info?.logo)
        try asset.insert(db); return asset
    }
    static func watchSolana(_ address: String, priority: Int, accountID: String, owner: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO solanaHistoryCursors(accountID,owner,address,priority) VALUES(?,?,?,?)
            ON CONFLICT(accountID,owner,address) DO UPDATE SET priority=MIN(priority,excluded.priority)
            """, arguments: [accountID,owner,address,priority])
    }
    public func commitSolanaInventory(_ inventory: SolanaInventory, ticket: SolanaSyncTicket, catalog: [String: SolanaTokenInfo]) async throws {
        guard inventory.owner == ticket.owner else { throw SolanaError.wrongOwner }
        var grouped: [String: (UInt64, Int)] = [:]
        for token in inventory.accounts {
            guard let amount = UInt64(token.amount) else { throw SolanaError.malformed }
            let previous = grouped[token.mint]
            let sum = (previous?.0 ?? 0).addingReportingOverflow(amount)
            guard !sum.overflow, previous == nil || previous?.1 == token.decimals else { throw SolanaError.malformed }
            grouped[token.mint] = (sum.partialValue, token.decimals)
        }
        let holdings = grouped
        let payload = try JSONEncoder().encode(inventory)
        try await pool.write { db in
            try Self.validateSolana(ticket, db: db)
            if let oldData = try Data.fetchOne(db, sql: "SELECT inventory FROM solanaSync WHERE accountID=? AND owner=?", arguments: [ticket.account.id,ticket.owner]) {
                let old = try JSONDecoder().decode(SolanaInventory.self, from: oldData)
                guard inventory.nativeSlot >= old.nativeSlot, inventory.tokenSlot >= old.tokenSlot,
                      inventory.token2022Slot >= old.token2022Slot else { throw SolanaError.staleSlot }
            }
            let now = inventory.fetchedAt.timeIntervalSince1970
            // Only a complete inventory of both programs replaces amounts.
            // Absent previously-held tokens become real zeroes on that address.
            try db.execute(sql: "UPDATE solanaHoldings SET amountAtomic='0',observedAt=?,slot=? WHERE accountID=? AND owner=?",
                arguments: [now,inventory.minimumSlot,ticket.account.id,ticket.owner])
            let native = try Self.solanaAsset(mint: "native", decimals: 9, info: nil, db: db)
            func save(_ assetID: String, amount: String, verified: Bool) throws {
                try db.execute(sql: """
                    INSERT INTO solanaHoldings(accountID,owner,assetID,amountAtomic,observedAt,slot,verified) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,owner,assetID) DO UPDATE SET amountAtomic=excluded.amountAtomic,
                        observedAt=excluded.observedAt,slot=excluded.slot,verified=excluded.verified
                    """, arguments: [ticket.account.id,ticket.owner,assetID,amount,now,inventory.minimumSlot,verified])
            }
            try save(native.id, amount: inventory.lamports, verified: true)
            for (mint, holding) in holdings {
                // On-chain precision is authoritative. Stale catalog entries
                // do not block the whole wallet or assign a mismatched price.
                let info = catalog[mint].flatMap { $0.decimals == holding.1 ? $0 : nil }
                let asset = try Self.solanaAsset(mint: mint, decimals: holding.1, info: info, db: db)
                try save(asset.id, amount: String(holding.0), verified: info != nil)
            }
            for token in inventory.accounts {
                try Self.watchSolana(token.address, priority: catalog[token.mint] != nil && token.amount != "0" ? 1 : 2,
                                     accountID: ticket.account.id, owner: ticket.owner, db: db)
            }
            try db.execute(sql: "UPDATE solanaSync SET inventory=?,observedAt=?,minimumSlot=?,failure=NULL WHERE accountID=? AND owner=?",
                arguments: [payload,now,inventory.minimumSlot,ticket.account.id,ticket.owner])
        }
    }
    public func solanaHistoryWork(_ ticket: SolanaSyncTicket, since: Double, limit: Int = 4) async throws -> [SolanaHistoryCursor] {
        try await pool.read { db in
            try Self.validateSolana(ticket, db: db)
            return try SolanaHistoryCursor.fetchAll(db, sql: """
                SELECT * FROM solanaHistoryCursors WHERE accountID=? AND owner=?
                AND (lastChecked<? OR complete=0 OR pendingBefore IS NOT NULL)
                ORDER BY priority,lastChecked,address LIMIT ?
                """, arguments: [ticket.account.id,ticket.owner,since,min(20,max(1,limit))])
        }
    }
    public func cachedSolanaTransactions(_ ticket: SolanaSyncTicket, signatures: [String]) async throws -> [SolanaTransaction] {
        try await pool.read { db in
            try Self.validateSolana(ticket, db: db)
            return try signatures.compactMap { signature in
                guard let data = try Data.fetchOne(db, sql: "SELECT detail FROM solanaTransactions WHERE accountID=? AND owner=? AND signature=?",
                    arguments: [ticket.account.id,ticket.owner,signature]) else { return nil }
                return try JSONDecoder().decode(SolanaTransaction.self, from: data)
            }
        }
    }
    public func commitSolanaHistory(_ transactions: [SolanaTransaction], page: SolanaSignaturePage, cursor: SolanaHistoryCursor,
        ticket: SolanaSyncTicket, backfill: Bool, pageSize: Int, catalog: [String: SolanaTokenInfo]) async throws {
        guard transactions.count == page.signatures.count,
              Set(transactions.map(\.signature)).count == transactions.count,
              Set(transactions.map(\.signature)) == Set(page.signatures.map(\.signature)),
              transactions.allSatisfy({ transaction in
                  page.signatures.contains { $0.signature == transaction.signature && $0.slot == transaction.slot && $0.failed == transaction.failed }
              }) else { throw SolanaError.incompleteHistory }
        let now = Date().timeIntervalSince1970
        try await pool.write { db in
            try Self.validateSolana(ticket, db: db)
            guard cursor.accountID == ticket.account.id, cursor.owner == ticket.owner,
                  let current = try SolanaHistoryCursor.fetchOne(db, key: ["accountID":cursor.accountID,"owner":cursor.owner,"address":cursor.address]) else { throw StoreError.staleSync }
            // Another history worker may discover this same token account and
            // promote its priority. That does not invalidate its in-flight page.
            var expected = cursor
            expected.priority = current.priority
            guard current == expected else { throw StoreError.staleSync }
            for value in transactions {
                let id = "solana:" + value.signature
                let timestamp = value.timestamp ?? page.signatures.first(where: { $0.signature == value.signature })?.blockTime ?? 0
                try TransactionRecord(id: id, networkID: "solana", hash: value.signature, state: value.failed ? "failed" : "confirmed",
                    blockHeight: Int64(value.slot), timestamp: timestamp, feeAtomic: value.fee, updatedAt: now).upsert(db)
                try db.execute(sql: "INSERT OR REPLACE INTO solanaTransactions(accountID,owner,signature,detail) VALUES(?,?,?,?)",
                    arguments: [ticket.account.id,ticket.owner,value.signature,try JSONEncoder().encode(value)])
                for change in value.changes {
                    let info = catalog[change.mint].flatMap { $0.decimals == change.decimals ? $0 : nil }
                    let asset = try Self.solanaAsset(mint: change.mint, decimals: change.decimals, info: info, db: db)
                    if change.direction=="outgoing",try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM sends WHERE accountID=? AND senderAddress=? AND transactionID=? AND assetID=? AND signedPayload IS NOT NULL)",arguments:[ticket.account.id,ticket.owner,id,asset.id]) == true { continue }
                    let activityID = ticket.account.id + ":" + ticket.owner + ":" + value.signature + ":" + change.mint
                    try ActivityRecord(id: activityID, walletID: ticket.account.walletID, accountID: ticket.account.id, networkID: "solana",
                        transactionID: id, assetID: asset.id, direction: change.direction, amountAtomic: change.amount,
                        counterparty: change.counterparty ?? "", timestamp: timestamp).upsert(db)
                    try db.execute(sql: "INSERT OR REPLACE INTO solanaActivity(activityID,owner) VALUES(?,?)", arguments: [activityID,ticket.owner])
                }
                for address in value.tokenAccounts {
                    // Retain closed token accounts found in older transactions.
                    try Self.watchSolana(address, priority: 1, accountID: ticket.account.id, owner: ticket.owner, db: db)
                }
            }
            // A recent-only response is useful, but it may not advance archive
            // cursors or falsely mark an older account's history complete.
            guard page.archival else { return }
            var next = current
            if backfill {
                if let last = page.signatures.last { guard last.signature != cursor.before else { throw SolanaError.malformed }; next.before = last.signature }
                next.complete = page.signatures.count < pageSize
            } else if cursor.head == nil {
                next.head = page.signatures.first?.signature
                next.before = page.signatures.last?.signature
                next.complete = page.signatures.count < pageSize
            } else {
                if next.pendingHead == nil { next.pendingHead = page.signatures.first?.signature }
                if page.signatures.count == pageSize {
                    guard page.signatures.last?.signature != cursor.pendingBefore else { throw SolanaError.malformed }
                    next.pendingBefore = page.signatures.last?.signature
                } else {
                    next.head = next.pendingHead ?? next.head; next.pendingBefore = nil; next.pendingHead = nil
                }
            }
            next.lastChecked = now
            try next.update(db)
            try db.execute(sql: "UPDATE solanaSync SET historyFailure=NULL WHERE accountID=? AND owner=?", arguments: [ticket.account.id,ticket.owner])
        }
        if !page.archival { throw SolanaError.incompleteHistory }
    }
}
