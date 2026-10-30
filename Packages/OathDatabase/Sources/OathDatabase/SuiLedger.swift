import Foundation
import GRDB
import OathAnkr

public struct SuiSyncTicket: Sendable { public let account:AccountRecord; public let runID:String }
public struct SuiHistoryCursor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "suiHistoryCursors"
    public let accountID:String
    public let lane:String
    public var beforeCursor:String?
    public var upperCheckpoint:Int64?
    public var oldestCheckpoint:Int64?
    public var stopHash:String?
    public var headHash:String?
    public var complete:Bool
}
extension OathDatabase {
    public func beginSuiSync(accountID:String) async throws -> SuiSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "sui" else { throw StoreError.missingRecord }
            _ = try SuiIdentity.address(account.address)
            let run = UUID().uuidString
            try db.execute(sql:"INSERT INTO suiSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL",arguments:[accountID,run])
            for lane in ["recent","backfill"] {
                var cursor = try SuiHistoryCursor.fetchOne(db,key:["accountID":accountID,"lane":lane]) ?? .init(accountID:accountID,lane:lane,complete:false)
                if lane == "recent", cursor.complete {
                    cursor.stopHash = cursor.headHash; cursor.headHash = nil; cursor.beforeCursor = nil
                    cursor.upperCheckpoint = nil; cursor.oldestCheckpoint = nil; cursor.complete = false
                }
                try cursor.upsert(db)
            }
            return .init(account:account,runID:run)
        }
    }
    static func validateSui(_ ticket:SuiSyncTicket, db:Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account,
              try String.fetchOne(db,sql:"SELECT runID FROM suiSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failSuiSync(_ ticket:SuiSyncTicket, history:Bool, code:String) async throws {
        try await pool.write { db in
            try Self.validateSui(ticket,db:db)
            try db.execute(sql:"UPDATE suiSync SET \(history ? "historyFailure":"failure")=? WHERE accountID=?",arguments:[code,ticket.account.id])
        }
    }
    public func suiInventory(accountID:String) async throws -> SuiInventory? {
        try await pool.read { db in
            guard let raw = try Data.fetchOne(db,sql:"SELECT inventory FROM suiSync WHERE accountID=?",arguments:[accountID]) else { return nil }
            return try JSONDecoder().decode(SuiInventory.self,from:raw)
        }
    }
    func suiInventoryCheckpoint(_ ticket: SuiSyncTicket) async throws -> Int64 {
        try await pool.read { db in
            try Self.validateSui(ticket, db: db)
            return try Int64.fetchOne(db, sql: "SELECT checkpoint FROM suiSync WHERE accountID=?", arguments: [ticket.account.id]) ?? 0
        }
    }
    private static func suiToken(_ reference:String, input:SuiToken?, db:Database) throws -> SuiToken? {
        if reference == "native" { return .native }
        if let input {
            guard input.reference == reference, (0...255).contains(input.decimals) else { throw SuiError.malformed }
            return input
        }
        guard let saved = try MarketCacheEntry.fetchOne(db,key:"sui.token."+reference) else { return nil }
        let token = try JSONDecoder().decode(SuiToken.self,from:saved.payload)
        guard token.reference == reference else { throw StoreError.conflictingIdentity }; return token
    }
    private static func suiAsset(_ token:SuiToken, db:Database) throws -> AssetRecord {
        guard try SuiIdentity.reference(token.reference) == token.reference else { throw StoreError.conflictingIdentity }
        try MarketCacheEntry(key:"sui.token."+token.reference,source:"Sui on-chain metadata",payload:try JSONEncoder().encode(token),fetchedAt:Date().timeIntervalSince1970).upsert(db)
        if var asset = try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='sui' AND reference=?",arguments:[token.reference]) {
            guard asset.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            asset.name = token.name; asset.symbol = token.symbol; asset.logo = token.logo ?? asset.logo
            try asset.update(db); return asset
        }
        let asset = AssetRecord(id:"sui:"+token.reference,networkID:"sui",reference:token.reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo)
        try asset.insert(db); return asset
    }
    public func commitSuiInventory(_ value:SuiInventory, ticket:SuiSyncTicket, catalog:SuiCatalog) async throws {
        guard value.owner == (try SuiIdentity.address(ticket.account.address)),
              Set(value.holdings.map(\.reference)).count == value.holdings.count,
              value.holdings.filter({$0.reference == "native"}).count == 1 else { throw SuiError.wrongOwner }
        try await pool.write { db in
            try Self.validateSui(ticket,db:db)
            let time = value.observedAt.timeIntervalSince1970
            let previous = try Double.fetchOne(db,sql:"SELECT observedAt FROM suiSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            let checkpoint = try Int64.fetchOne(db,sql:"SELECT checkpoint FROM suiSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            guard time >= previous, value.checkpoint >= checkpoint else { throw StoreError.staleSync }
            // A complete, pinned inventory is the only operation that clears
            // spent tokens. Unknown metadata still keeps its exact raw balance.
            try db.execute(sql:"UPDATE suiHoldings SET amountAtomic='0',coinBalance='0',addressBalance='0',observedAt=?,checkpoint=? WHERE accountID=?",arguments:[time,value.checkpoint,ticket.account.id])
            for holding in value.holdings {
                guard try SuiIdentity.reference(holding.reference) == holding.reference else { throw StoreError.conflictingIdentity }
                _ = try AtomicAmount(holding.amount); _ = try AtomicAmount(holding.coinBalance); _ = try AtomicAmount(holding.addressBalance)
                let token = try Self.suiToken(holding.reference,input:holding.token,db:db)
                let asset = try token.map{try Self.suiAsset($0,db:db)}
                try db.execute(sql:"""
                    INSERT INTO suiHoldings(accountID,reference,assetID,amountAtomic,coinBalance,addressBalance,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET assetID=excluded.assetID,amountAtomic=excluded.amountAtomic,coinBalance=excluded.coinBalance,addressBalance=excluded.addressBalance,observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=excluded.verified
                    """,arguments:[ticket.account.id,holding.reference,asset?.id,holding.amount,holding.coinBalance,holding.addressBalance,time,value.checkpoint,catalog.contains(holding.reference)])
            }
            try db.execute(sql:"UPDATE suiSync SET inventory=?,observedAt=?,checkpoint=?,failure=NULL WHERE accountID=?",arguments:[try JSONEncoder().encode(value),time,value.checkpoint,ticket.account.id])
            // Metadata may have become available since a historical transfer.
            // Re-project saved receipts without another history request.
            for row in try Row.fetchAll(db,sql:"SELECT detail FROM suiTransactions WHERE accountID=? AND unresolved=1",arguments:[ticket.account.id]) {
                let tx = try JSONDecoder().decode(SuiTransaction.self,from:row["detail"])
                try Self.projectSui(tx,ticket:ticket,db:db)
            }
        }
    }
    public func suiHistoryWork(_ ticket:SuiSyncTicket) async throws -> [SuiHistoryCursor] {
        try await pool.read { db in
            try Self.validateSui(ticket,db:db)
            return try SuiHistoryCursor.fetchAll(db,sql:"SELECT * FROM suiHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC LIMIT 1",arguments:[ticket.account.id])
        }
    }
    /// Cursors can expire on a provider. Restart at the last checkpoint with
    /// overlap, so transactions sharing its boundary are never skipped.
    public func restartSuiHistory(_ cursor:SuiHistoryCursor, ticket:SuiSyncTicket) async throws {
        try await pool.write { db in
            try Self.validateSui(ticket,db:db)
            guard try SuiHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":cursor.lane]) == cursor, cursor.beforeCursor != nil else { throw StoreError.staleSync }
            var next = cursor; next.beforeCursor = nil; next.upperCheckpoint = cursor.oldestCheckpoint.map{$0+1}
            try next.update(db)
        }
    }
    private static func projectSui(_ tx:SuiTransaction, ticket:SuiSyncTicket, db:Database) throws {
        guard tx.owner == (try SuiIdentity.address(ticket.account.address)) else { throw SuiError.wrongOwner }
        let id = "sui:"+tx.hash, now = Date().timeIntervalSince1970
        try TransactionRecord(id:id,networkID:"sui",hash:tx.hash,state:tx.failed ? "failed":"confirmed",blockHeight:tx.checkpoint,timestamp:tx.timestamp,feeAtomic:tx.netGas.hasPrefix("-") ? "0":tx.netGas,updatedAt:now).upsert(db)
        var unresolved = false
        for movement in tx.movements {
            guard ["incoming","outgoing","self"].contains(movement.direction), try SuiIdentity.reference(movement.reference) == movement.reference else { throw SuiError.malformed }
            _ = try AtomicAmount(movement.amount)
            guard let token = try Self.suiToken(movement.reference,input:movement.token,db:db) else { unresolved = true; continue }
            let asset = try Self.suiAsset(token,db:db)
            // Balance deltas are net effects, not necessarily simple transfers:
            // swaps and multi-party calls have no single reliable counterparty.
            try ActivityRecord(id:ticket.account.id+":"+tx.hash+":"+movement.reference,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"sui",transactionID:id,assetID:asset.id,direction:movement.direction,amountAtomic:movement.amount,counterparty:"",timestamp:tx.timestamp).upsert(db)
        }
        try db.execute(sql:"INSERT OR REPLACE INTO suiTransactions(accountID,hash,checkpoint,detail,unresolved) VALUES(?,?,?,?,?)",arguments:[ticket.account.id,tx.hash,tx.checkpoint,try JSONEncoder().encode(tx),unresolved])
    }
    public func commitSuiPage(_ page:SuiHistoryPage, cursor:SuiHistoryCursor, ticket:SuiSyncTicket) async throws {
        guard cursor.accountID == ticket.account.id, page.next == nil || (page.next != cursor.beforeCursor && !page.transactions.isEmpty),
              page.head == page.transactions.first?.hash, Set(page.transactions.map(\.hash)).count == page.transactions.count else { throw SuiError.paginationLoop }
        try await pool.write { db in
            try Self.validateSui(ticket,db:db)
            guard try SuiHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            for tx in page.transactions { try Self.projectSui(tx,ticket:ticket,db:db) }
            try db.execute(sql:"INSERT OR REPLACE INTO suiPages(accountID,pageKey,raw) VALUES(?,?,?)",arguments:[ticket.account.id,cursor.beforeCursor ?? "first:\(cursor.upperCheckpoint ?? 0)",page.raw])
            var backlog = try SuiHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":"backfill"])
            if cursor.lane == "recent", cursor.stopHash == nil, cursor.beforeCursor == nil,
               var initial = backlog, initial.headHash == nil, initial.beforeCursor == nil, !initial.complete {
                initial.headHash = page.head; initial.beforeCursor = page.next; initial.oldestCheckpoint = page.transactions.map(\.checkpoint).min(); initial.complete = page.next == nil
                try initial.update(db); backlog = initial
            }
            var next = cursor
            next.headHash = cursor.headHash ?? page.head ?? cursor.stopHash; next.beforeCursor = page.next
            next.oldestCheckpoint = page.transactions.map(\.checkpoint).min() ?? cursor.oldestCheckpoint
            let reached = cursor.stopHash.map { stop in page.transactions.contains{$0.hash == stop} } ?? false
            next.complete = page.next == nil || (cursor.lane == "recent" && (reached || (cursor.stopHash == nil && backlog?.complete == false)))
            try next.update(db)
        }
    }
}
