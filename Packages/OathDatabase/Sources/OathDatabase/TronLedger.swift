import Foundation
import GRDB
import OathAnkr

public struct TronSyncTicket: Sendable { public let account: AccountRecord; public let runID: String }
public struct TronHistoryCursor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tronHistoryCursors"
    public let accountID: String
    public let stream: String
    public let lane: String
    public var start: Int64
    public var end: Int64
    public var cursor: String?
    public var complete: Bool
}
extension OathDatabase {
    public func beginTronSync(accountID: String, now: Date = .now) async throws -> TronSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "tron",
                  TronIdentity.isAddress(account.address) else { throw StoreError.missingRecord }
            let run = UUID().uuidString
            try db.execute(sql: "INSERT INTO tronSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL", arguments: [accountID,run])
            let end = Int64(now.timeIntervalSince1970 * 1000)
            for stream in TronStream.allCases {
                for lane in ["recent", "backfill"] {
                    var cursor = try TronHistoryCursor.fetchOne(db, key: ["accountID":accountID,"stream":stream.rawValue,"lane":lane])
                        ?? .init(accountID: accountID, stream: stream.rawValue, lane: lane, start: lane == "recent" ? max(0,end-86_400_000) : 0, end: end, complete: false)
                    if lane == "recent", cursor.complete { cursor.start = max(0,cursor.end-86_400_000); cursor.end = end; cursor.cursor = nil; cursor.complete = false }
                    try cursor.upsert(db)
                }
            }
            return .init(account: account, runID: run)
        }
    }
    static func validateTron(_ ticket: TronSyncTicket, db: Database) throws {
        guard let current = try AccountRecord.fetchOne(db, key: ticket.account.id), current == ticket.account,
              try String.fetchOne(db, sql: "SELECT runID FROM tronSync WHERE accountID=?", arguments: [current.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failTronSync(_ ticket: TronSyncTicket, history: Bool, code: String) async throws {
        try await pool.write { db in
            try Self.validateTron(ticket, db: db)
            try db.execute(sql: "UPDATE tronSync SET \(history ? "historyFailure" : "failure")=? WHERE accountID=?", arguments: [code,ticket.account.id])
        }
    }
    public func tronInventory(accountID: String) async throws -> TronInventory? {
        try await pool.read { db in
            guard let raw = try Data.fetchOne(db, sql: "SELECT inventory FROM tronSync WHERE accountID=?", arguments: [accountID]) else { return nil }
            return try JSONDecoder().decode(TronInventory.self, from: raw)
        }
    }
    static func tronAsset(_ token: TronToken, catalog: [String: TronMarketTokenInfo], db: Database) throws -> AssetRecord {
        guard token.reference == "native" || TronIdentity.isToken(token.reference), (0...255).contains(token.decimals) else { throw TronError.malformed }
        let info = catalog[token.reference].flatMap { $0.decimals == token.decimals && $0.address == token.reference ? $0 : nil }
        if let info {
            try HistorySafety.trust(networkID: "tron", reference: info.address, decimals: info.decimals,
                source: "verified.history.catalog", observedAt: Date().timeIntervalSince1970, db: db)
        }
        if var existing = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID='tron' AND reference=?", arguments: [token.reference]) {
            guard existing.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            if let info { existing.name = info.name; existing.symbol = info.symbol }
            existing.logo = info?.logo ?? token.logo ?? existing.logo
            try existing.update(db)
            return existing
        }
        let asset = AssetRecord(id: "tron:" + token.reference, networkID: "tron", reference: token.reference,
            name: info?.name ?? token.name, symbol: info?.symbol ?? token.symbol, decimals: token.decimals, logo: info?.logo ?? token.logo)
        try asset.insert(db); return asset
    }
    public func commitTronInventory(_ value: TronInventory, ticket: TronSyncTicket, catalog: [String: TronMarketTokenInfo]) async throws {
        guard value.owner == ticket.account.address, Set(value.holdings.map { $0.token.reference }).count == value.holdings.count,
              value.holdings.filter({ $0.token.reference == "native" }).count == 1 else { throw TronError.wrongOwner }
        try await pool.write { db in
            try Self.validateTron(ticket, db: db)
            let now = value.observedAt.timeIntervalSince1970
            let old = try Double.fetchOne(db, sql: "SELECT observedAt FROM tronSync WHERE accountID=?", arguments: [ticket.account.id]) ?? 0
            guard now >= old else { throw StoreError.staleSync }
            // Failed individual reads retain their old values. Only tokens
            // absent from a successful full discovery can be zeroed.
            let found = Set(value.holdings.map { $0.token.reference }).union(value.failedReferences)
            for row in try Row.fetchAll(db, sql: "SELECT h.assetID,a.reference FROM tronHoldings h JOIN assets a ON a.id=h.assetID WHERE h.accountID=?", arguments: [ticket.account.id]) {
                let reference: String = row["reference"]
                if !found.contains(reference), value.discoveryComplete || TronIdentity.isTRC10(reference) { try db.execute(sql: "UPDATE tronHoldings SET amountAtomic='0',observedAt=? WHERE accountID=? AND assetID=?", arguments: [now,ticket.account.id,row["assetID"] as String]) }
            }
            for holding in value.holdings {
                _ = try AtomicAmount(holding.amount)
                let asset = try Self.tronAsset(holding.token, catalog: catalog, db: db)
                let verified = asset.reference == "native" || catalog[asset.reference]?.decimals == asset.decimals
                try db.execute(sql: """
                    INSERT INTO tronHoldings(accountID,assetID,amountAtomic,observedAt,verified) VALUES(?,?,?,?,?)
                    ON CONFLICT(accountID,assetID) DO UPDATE SET amountAtomic=excluded.amountAtomic,observedAt=excluded.observedAt,verified=excluded.verified
                    """, arguments: [ticket.account.id,asset.id,holding.amount,now,verified])
            }
            try db.execute(sql: "UPDATE tronSync SET inventory=?,observedAt=?,failure=? WHERE accountID=?", arguments: [try JSONEncoder().encode(value),now,value.failedReferences.isEmpty && value.discoveryComplete ? nil : "partialInventory",ticket.account.id])
        }
    }
    public func tronHistoryWork(_ ticket: TronSyncTicket) async throws -> [TronHistoryCursor] {
        try await pool.read { db in
            try Self.validateTron(ticket, db: db)
            let cursors = try TronHistoryCursor.fetchAll(db, sql: "SELECT * FROM tronHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC,stream", arguments: [ticket.account.id])
            var seen: Set<String> = []
            return cursors.filter { seen.insert($0.stream).inserted }
        }
    }
    public func restartTronCursor(_ cursor: TronHistoryCursor, ticket: TronSyncTicket) async throws -> TronHistoryCursor {
        guard cursor.accountID == ticket.account.id else { throw StoreError.staleSync }
        return try await pool.write { db in
            try Self.validateTron(ticket, db: db)
            guard try TronHistoryCursor.fetchOne(db, key: ["accountID":cursor.accountID,"stream":cursor.stream,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            // Fingerprints can expire. Replaying the same window must not
            // mistake pages from the previous attempt for a new cursor loop.
            // Transaction receipts and activity stay cached throughout replay.
            try db.execute(sql: "DELETE FROM tronPages WHERE accountID=? AND stream=? AND start=? AND end=?", arguments: [ticket.account.id,cursor.stream,cursor.start,cursor.end])
            var next = cursor; next.cursor = nil; try next.update(db); return next
        }
    }
    public func tronTransaction(accountID: String, hash: String) async throws -> TronTransaction? {
        try await pool.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT detail FROM tronTransactions WHERE accountID=? AND hash=?", arguments: [accountID,hash]) else { return nil }
            return try JSONDecoder().decode(TronTransaction.self, from: data)
        }
    }
    public func commitTronPage(_ page: TronHistoryPage, transactions: [TronTransaction], tokens: [String: TronToken], catalog: [String: TronMarketTokenInfo], cursor: TronHistoryCursor, ticket: TronSyncTicket) async throws {
        guard cursor.accountID == ticket.account.id else { throw StoreError.staleSync }
        guard Set(page.hashes) == Set(transactions.map(\.hash)), transactions.count == page.hashes.count,
              page.cursor == nil || page.cursor != cursor.cursor else { throw TronError.incomplete }
        try await pool.write { db in
            try Self.validateTron(ticket, db: db)
            guard try TronHistoryCursor.fetchOne(db, key: ["accountID":cursor.accountID,"stream":cursor.stream,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            if let next = page.cursor, try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tronPages WHERE accountID=? AND stream=? AND start=? AND end=? AND pageKey=?)", arguments: [ticket.account.id,cursor.stream,cursor.start,cursor.end,next]) == true { throw TronError.paginationLoop }
            let now = Date().timeIntervalSince1970
            for tx in transactions {
                let id = "tron:" + tx.hash
                try TransactionRecord(id: id, networkID: "tron", hash: tx.hash, state: tx.failed ? "failed" : tx.confirmed ? "confirmed" : "pending", blockHeight: tx.block, timestamp: tx.timestamp, feeAtomic: tx.fee, updatedAt: now).upsert(db)
                try db.execute(sql: "INSERT OR REPLACE INTO tronTransactions(accountID,hash,detail) VALUES(?,?,?)", arguments: [ticket.account.id,tx.hash,try JSONEncoder().encode(tx)])
                // A newly solid receipt replaces tentative events, including
                // events removed by a failed execution or a pre-finality reorg.
                try db.execute(sql: "DELETE FROM activity WHERE accountID=? AND transactionID=?", arguments: [ticket.account.id,id])
                try db.execute(sql: "DELETE FROM transfers WHERE transactionID=? AND (fromAddress=? OR toAddress=?)", arguments: [id,ticket.account.address,ticket.account.address])
                // Stable receipt event indexes deduplicate all three index streams.
                var hasNative = false
                for event in tx.events where event.from == ticket.account.address || event.to == ticket.account.address {
                    guard let token = tokens[event.reference] else { throw TronError.incomplete }
                    _ = try AtomicAmount(event.amount)
                    let asset = try Self.tronAsset(token, catalog: catalog, db: db)
                    let direction = event.from == event.to ? "self" : event.to == ticket.account.address ? "incoming" : "outgoing"
                    let activityID = ticket.account.id + ":" + tx.hash + ":" + String(event.index)
                    try ActivityRecord(id: activityID, walletID: ticket.account.walletID, accountID: ticket.account.id, networkID: "tron", transactionID: id, assetID: asset.id, direction: direction, amountAtomic: event.amount, counterparty: direction == "incoming" ? event.from : event.to, timestamp: tx.timestamp).upsert(db)
                    try TransferRecord(id: "tron:"+tx.hash+":"+String(event.index), transactionID: id, networkID: "tron", assetID: asset.id, eventIndex: event.index, fromAddress: event.from, toAddress: event.to, amountAtomic: event.amount).upsert(db)
                    if event.reference == "native" { hasNative = true }
                }
                if tx.payer == ticket.account.address, !hasNative {
                    guard let native = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID='tron' AND reference='native'") else { throw StoreError.missingRecord }
                    try ActivityRecord(id: ticket.account.id+":"+tx.hash+":interaction", walletID: ticket.account.walletID, accountID: ticket.account.id, networkID: "tron", transactionID: id, assetID: native.id, direction: "self", amountAtomic: "0", counterparty: "", timestamp: tx.timestamp).upsert(db)
                }
            }
            try db.execute(sql: "INSERT OR REPLACE INTO tronPages(accountID,stream,start,end,pageKey,raw) VALUES(?,?,?,?,?,?)", arguments: [ticket.account.id,cursor.stream,cursor.start,cursor.end,cursor.cursor ?? "first",page.raw])
            var next = cursor; next.cursor = page.cursor; next.complete = page.cursor == nil; try next.update(db)
        }
    }
}
