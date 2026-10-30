import Foundation
import GRDB
import OathAnkr

public struct XrplSyncTicket: Sendable { public let account:AccountRecord; public let runID:String }
public struct XrplHistoryCursor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "xrplHistoryCursors"
    public let accountID:String
    public let lane:String
    public var beforeCursor:String?
    public var upperLedger:Int64?
    public var oldestLedger:Int64?
    public var stopHash:String?
    public var headHash:String?
    public var complete:Bool
}
extension OathDatabase {
    public func beginXrplSync(accountID:String) async throws -> XrplSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "xrpl" else { throw StoreError.missingRecord }
            _ = try XrplIdentity.address(account.address)
            let run = UUID().uuidString
            try db.execute(sql:"INSERT INTO xrplSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL",arguments:[accountID,run])
            for lane in ["recent","backfill"] {
                var cursor = try XrplHistoryCursor.fetchOne(db,key:["accountID":accountID,"lane":lane]) ?? .init(accountID:accountID,lane:lane,complete:false)
                if lane == "recent", cursor.complete {
                    cursor.stopHash = cursor.headHash; cursor.headHash = nil; cursor.beforeCursor = nil
                    cursor.upperLedger = nil; cursor.oldestLedger = nil; cursor.complete = false
                }
                try cursor.upsert(db)
            }
            return .init(account:account,runID:run)
        }
    }
    static func validateXrpl(_ ticket:XrplSyncTicket, db:Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account,
              try String.fetchOne(db,sql:"SELECT runID FROM xrplSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failXrplSync(_ ticket:XrplSyncTicket, history:Bool, code:String) async throws {
        try await pool.write { db in
            try Self.validateXrpl(ticket,db:db)
            try db.execute(sql:"UPDATE xrplSync SET \(history ? "historyFailure":"failure")=? WHERE accountID=?",arguments:[code,ticket.account.id])
        }
    }
    public func xrplInventory(accountID:String) async throws -> XrplInventory? {
        try await pool.read { db in
            guard let raw = try Data.fetchOne(db,sql:"SELECT inventory FROM xrplSync WHERE accountID=?",arguments:[accountID]) else { return nil }
            return try JSONDecoder().decode(XrplInventory.self,from:raw)
        }
    }
    private static func xrplToken(_ reference:String, input:XrplToken?, db:Database) throws -> XrplToken? {
        if reference == "native" { return .native }
        if input == nil, reference.contains(".") { return try .issued(reference) }
        if let input {
            guard input.reference == reference, (0...255).contains(input.decimals) else { throw XrplError.malformed }
            return input
        }
        guard let saved = try MarketCacheEntry.fetchOne(db,key:"xrpl.token."+reference) else { return nil }
        let token = try JSONDecoder().decode(XrplToken.self,from:saved.payload)
        guard token.reference == reference else { throw StoreError.conflictingIdentity }; return token
    }
    private static func xrplAsset(_ token:XrplToken, db:Database) throws -> AssetRecord {
        guard try XrplIdentity.reference(token.reference) == token.reference else { throw StoreError.conflictingIdentity }
        var metadata = token
        if token.name == token.symbol, let saved = try MarketCacheEntry.fetchOne(db,key:"xrpl.token."+token.reference),
           let richer = try? JSONDecoder().decode(XrplToken.self,from:saved.payload), richer.reference == token.reference, richer.decimals == token.decimals, richer.name != richer.symbol { metadata = richer }
        try MarketCacheEntry(key:"xrpl.token."+token.reference,source:"XRP Ledger metadata",payload:try JSONEncoder().encode(metadata),fetchedAt:Date().timeIntervalSince1970).upsert(db)
        if var asset = try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='xrpl' AND reference=?",arguments:[token.reference]) {
            guard asset.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            if token.name != token.symbol || asset.name == asset.symbol { asset.name = token.name; asset.symbol = token.symbol }; asset.logo = token.logo ?? asset.logo
            try asset.update(db); return asset
        }
        let asset = AssetRecord(id:"xrpl:"+token.reference,networkID:"xrpl",reference:token.reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo)
        try asset.insert(db); return asset
    }
    public func commitXrplInventory(_ value:XrplInventory, ticket:XrplSyncTicket, catalog:XrplCatalog) async throws {
        guard value.observedAt.timeIntervalSince1970.isFinite, value.ledger.height >= 0, value.owner == (try XrplIdentity.address(ticket.account.address)),
              Set(value.holdings.map(\.reference)).count == value.holdings.count,
              value.holdings.filter({$0.reference == "native"}).count == 1 else { throw XrplError.wrongOwner }
        try await pool.write { db in
            try Self.validateXrpl(ticket,db:db)
            let time = value.observedAt.timeIntervalSince1970
            let previous = try Double.fetchOne(db,sql:"SELECT observedAt FROM xrplSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            let checkpoint = try Int64.fetchOne(db,sql:"SELECT checkpoint FROM xrplSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            guard time >= previous, value.ledger.height >= checkpoint else { throw StoreError.staleSync }
            // A complete, pinned inventory is the only operation that clears
            // spent tokens. Unknown metadata still keeps its exact raw balance.
            try db.execute(sql:"UPDATE xrplHoldings SET amountAtomic='0',signedAmount='0',observedAt=?,checkpoint=? WHERE accountID=?",arguments:[time,value.ledger.height,ticket.account.id])
            for holding in value.holdings {
                guard try XrplIdentity.reference(holding.reference) == holding.reference else { throw StoreError.conflictingIdentity }
                _ = try AtomicAmount(holding.amount.hasPrefix("-") ? String(holding.amount.dropFirst()):holding.amount)
                let token = try Self.xrplToken(holding.reference,input:catalog.tokens[holding.reference] ?? holding.token,db:db)
                let asset = try token.map{try Self.xrplAsset($0,db:db)}
                try db.execute(sql:"""
                    INSERT INTO xrplHoldings(accountID,reference,assetID,amountAtomic,signedAmount,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET assetID=excluded.assetID,amountAtomic=excluded.amountAtomic,signedAmount=excluded.signedAmount,observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=excluded.verified
                    """,arguments:[ticket.account.id,holding.reference,asset?.id,holding.amount.hasPrefix("-") ? "0":holding.amount,holding.amount,time,value.ledger.height,catalog.contains(holding.reference)])
            }
            try db.execute(sql:"UPDATE xrplSync SET inventory=?,observedAt=?,checkpoint=?,failure=NULL WHERE accountID=?",arguments:[try JSONEncoder().encode(value),time,value.ledger.height,ticket.account.id])
            // Metadata may have become available since a historical transfer.
            // Re-project saved receipts without another history request.
            for row in try Row.fetchAll(db,sql:"SELECT detail FROM xrplTransactions WHERE accountID=? AND unresolved=1",arguments:[ticket.account.id]) {
                let tx = try JSONDecoder().decode(XrplTransaction.self,from:row["detail"])
                try Self.projectXrpl(tx,ticket:ticket,db:db)
            }
        }
    }
    public func xrplHistoryWork(_ ticket:XrplSyncTicket) async throws -> [XrplHistoryCursor] {
        try await pool.read { db in
            try Self.validateXrpl(ticket,db:db)
            return try XrplHistoryCursor.fetchAll(db,sql:"SELECT * FROM xrplHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC LIMIT 1",arguments:[ticket.account.id])
        }
    }
    /// Cursors can expire on a provider. Restart at the last checkpoint with
    /// overlap, so transactions sharing its boundary are never skipped.
    public func restartXrplHistory(_ cursor:XrplHistoryCursor, ticket:XrplSyncTicket) async throws {
        try await pool.write { db in
            try Self.validateXrpl(ticket,db:db)
            guard try XrplHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":cursor.lane]) == cursor, cursor.beforeCursor != nil else { throw StoreError.staleSync }
            var next = cursor; next.beforeCursor = nil; next.upperLedger = cursor.oldestLedger
            try next.update(db)
        }
    }
    /// ANKR's rolling window can pass an offline cursor. Finish expired
    /// backfill or restart the recent lane; never erase saved transactions.
    public func expireXrplHistoryWindow(_ cursor:XrplHistoryCursor, ticket:XrplSyncTicket) async throws {
        try await pool.write { db in
            try Self.validateXrpl(ticket,db:db)
            guard cursor.accountID == ticket.account.id,
                  try XrplHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":cursor.lane]) == cursor,
                  cursor.upperLedger != nil else { throw StoreError.staleSync }
            var next = cursor
            next.beforeCursor = nil; next.upperLedger = nil; next.oldestLedger = nil
            if cursor.lane == "backfill" { next.complete = true }
            else { next.stopHash = cursor.headHash ?? cursor.stopHash; next.headHash = nil; next.complete = false }
            try next.update(db)
        }
    }
    private static func projectXrpl(_ tx:XrplTransaction, ticket:XrplSyncTicket, db:Database) throws {
        guard tx.owner == (try XrplIdentity.address(ticket.account.address)) else { throw XrplError.wrongOwner }
        let id = "xrpl:"+tx.hash, now = Date().timeIntervalSince1970
        try TransactionRecord(id:id,networkID:"xrpl",hash:tx.hash,state:tx.failed ? "failed":"confirmed",blockHeight:tx.checkpoint,timestamp:tx.timestamp,feeAtomic:tx.fee,updatedAt:now).upsert(db)
        var unresolved = false
        for movement in tx.movements {
            guard ["incoming","outgoing","self"].contains(movement.direction), try XrplIdentity.reference(movement.reference) == movement.reference else { throw XrplError.malformed }
            _ = try AtomicAmount(movement.amount)
            guard let token = try Self.xrplToken(movement.reference,input:movement.token,db:db) else { unresolved = true; continue }
            let asset = try Self.xrplAsset(token,db:db)
            // Balance deltas are net effects, not necessarily simple transfers:
            // swaps and multi-party calls have no single reliable counterparty.
            try ActivityRecord(id:ticket.account.id+":"+tx.hash+":"+movement.reference,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"xrpl",transactionID:id,assetID:asset.id,direction:movement.direction,amountAtomic:movement.amount,counterparty:tx.counterparty ?? "",timestamp:tx.timestamp).upsert(db)
        }
        try db.execute(sql:"INSERT OR REPLACE INTO xrplTransactions(accountID,hash,checkpoint,detail,unresolved) VALUES(?,?,?,?,?)",arguments:[ticket.account.id,tx.hash,tx.checkpoint,try JSONEncoder().encode(tx),unresolved])
    }
    public func commitXrplPage(_ page:XrplHistoryPage, cursor:XrplHistoryCursor, ticket:XrplSyncTicket) async throws {
        guard cursor.accountID == ticket.account.id, (cursor.upperLedger == nil || cursor.upperLedger == page.upperLedger), page.transactions.allSatisfy({$0.checkpoint <= page.upperLedger}), page.next == nil || (page.next != cursor.beforeCursor && !page.transactions.isEmpty),
              page.head == page.transactions.first?.hash, Set(page.transactions.map(\.hash)).count == page.transactions.count else { throw XrplError.paginationLoop }
        try await pool.write { db in
            try Self.validateXrpl(ticket,db:db)
            guard try XrplHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            for tx in page.transactions { try Self.projectXrpl(tx,ticket:ticket,db:db) }
            try db.execute(sql:"INSERT OR REPLACE INTO xrplPages(accountID,pageKey,raw) VALUES(?,?,?)",arguments:[ticket.account.id,cursor.beforeCursor ?? "first:\(cursor.upperLedger ?? 0)",page.raw])
            var backlog = try XrplHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":"backfill"])
            if cursor.lane == "recent", cursor.stopHash == nil, cursor.beforeCursor == nil,
               var initial = backlog, initial.headHash == nil, initial.beforeCursor == nil, !initial.complete {
                initial.headHash = page.head; initial.beforeCursor = page.next; initial.upperLedger = page.upperLedger; initial.oldestLedger = page.transactions.map(\.checkpoint).min(); initial.complete = page.next == nil
                try initial.update(db); backlog = initial
            }
            var next = cursor
            next.headHash = cursor.headHash ?? page.head ?? cursor.stopHash; next.beforeCursor = page.next; next.upperLedger = page.upperLedger
            next.oldestLedger = page.transactions.map(\.checkpoint).min() ?? cursor.oldestLedger
            let reached = cursor.stopHash.map { stop in page.transactions.contains{$0.hash == stop} } ?? false
            next.complete = page.next == nil || (cursor.lane == "recent" && (reached || (cursor.stopHash == nil && backlog?.complete == false)))
            try next.update(db)
        }
    }
}
