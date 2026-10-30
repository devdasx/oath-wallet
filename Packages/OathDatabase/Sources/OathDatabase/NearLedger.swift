import Foundation
import GRDB
import OathAnkr

public struct NearSyncTicket:Sendable { public let account:AccountRecord; public let runID:String }
public struct NearHistoryCursor:Codable,Sendable,Equatable,FetchableRecord,PersistableRecord {
    public static let databaseTableName = "nearHistoryCursors"
    public let accountID:String
    public let stream:String
    public let lane:String
    public var beforeCursor:String?
    public var stopID:String?
    public var headID:String?
    public var complete:Bool
}
extension OathDatabase {
    public func beginNearSync(accountID:String) async throws -> NearSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "near" else { throw StoreError.missingRecord }
            _ = try NearIdentity.address(account.address)
            let run = UUID().uuidString
            try db.execute(sql:"INSERT INTO nearSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL",arguments:[accountID,run])
            for stream in ["transfers","transactions"] { for lane in ["recent","backfill"] {
                var cursor = try NearHistoryCursor.fetchOne(db,key:["accountID":accountID,"stream":stream,"lane":lane]) ?? .init(accountID:accountID,stream:stream,lane:lane,complete:false)
                if lane == "recent", cursor.complete { cursor.stopID = cursor.headID; cursor.headID = nil; cursor.beforeCursor = nil; cursor.complete = false }
                try cursor.upsert(db)
            } }
            return .init(account:account,runID:run)
        }
    }
    static func validateNear(_ ticket:NearSyncTicket, db:Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account,
              try String.fetchOne(db,sql:"SELECT runID FROM nearSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failNearSync(_ ticket:NearSyncTicket, history:Bool, code:String) async throws {
        try await pool.write { db in
            try Self.validateNear(ticket,db:db)
            try db.execute(sql:"UPDATE nearSync SET \(history ? "historyFailure":"failure")=? WHERE accountID=?",arguments:[code,ticket.account.id])
        }
    }
    public func nearInventory(accountID:String) async throws -> NearInventory? {
        try await pool.read { db in
            guard let data = try Data.fetchOne(db,sql:"SELECT inventory FROM nearSync WHERE accountID=?",arguments:[accountID]) else { return nil }
            return try JSONDecoder().decode(NearInventory.self,from:data)
        }
    }
    public func nearKnownReferences(accountID:String) async throws -> [String] {
        try await pool.read { db in
            try String.fetchAll(db,sql:"""
                SELECT reference FROM nearHoldings WHERE accountID=?
                UNION SELECT a.reference FROM trackedAssets t JOIN assets a ON a.id=t.assetID WHERE t.accountID=? AND a.networkID='near'
                """,arguments:[accountID,accountID])
        }
    }
    private static func nearToken(_ reference:String, input:NearToken?, db:Database) throws -> NearToken? {
        if reference == "native" { return .native }
        if let input {
            guard input.reference == reference, (0...255).contains(input.decimals) else { throw NearError.malformed }; return input
        }
        guard let saved = try MarketCacheEntry.fetchOne(db,key:"near.token."+reference) else { return nil }
        let token = try JSONDecoder().decode(NearToken.self,from:saved.payload)
        guard token.reference == reference else { throw StoreError.conflictingIdentity }; return token
    }
    private static func nearAsset(_ token:NearToken, db:Database) throws -> AssetRecord {
        guard try NearIdentity.reference(token.reference) == token.reference else { throw StoreError.conflictingIdentity }
        try MarketCacheEntry(key:"near.token."+token.reference,source:"NEAR on-chain metadata",payload:try JSONEncoder().encode(token),fetchedAt:Date().timeIntervalSince1970).upsert(db)
        if var asset = try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='near' AND reference=?",arguments:[token.reference]) {
            guard asset.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            asset.name = token.name; asset.symbol = token.symbol; asset.logo = token.logo ?? asset.logo; try asset.update(db); return asset
        }
        let asset = AssetRecord(id:"near:"+token.reference,networkID:"near",reference:token.reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo)
        try asset.insert(db); return asset
    }
    public func commitNearInventory(_ value:NearInventory, ticket:NearSyncTicket, catalog:NearCatalog) async throws {
        guard value.owner == ticket.account.address, Set(value.holdings.map(\.reference)).count == value.holdings.count,
              value.holdings.filter({$0.reference == "native"}).count == 1, value.observedAt.timeIntervalSince1970.isFinite else { throw NearError.wrongOwner }
        try await pool.write { db in
            try Self.validateNear(ticket,db:db)
            let time = value.observedAt.timeIntervalSince1970
            let previous = try Double.fetchOne(db,sql:"SELECT observedAt FROM nearSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            let height = try Int64.fetchOne(db,sql:"SELECT blockHeight FROM nearSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            guard time >= previous, value.block.height >= height else { throw StoreError.staleSync }
            for holding in value.holdings {
                guard try NearIdentity.reference(holding.reference) == holding.reference else { throw StoreError.conflictingIdentity }
                if let amount = holding.amount { _ = try AtomicAmount(amount) }
                let token = try Self.nearToken(holding.reference,input:holding.token,db:db)
                let asset = try token.map{try Self.nearAsset($0,db:db)}
                // Failed per-contract reads retain the last successful amount
                // and its timestamp. Missing metadata retains exact raw units.
                try db.execute(sql:"""
                    INSERT INTO nearHoldings(accountID,reference,assetID,amountAtomic,observedAt,blockHeight,verified,failure) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET
                      assetID=COALESCE(excluded.assetID,nearHoldings.assetID),
                      amountAtomic=COALESCE(excluded.amountAtomic,nearHoldings.amountAtomic),
                      observedAt=CASE WHEN excluded.amountAtomic IS NULL THEN nearHoldings.observedAt ELSE excluded.observedAt END,
                      blockHeight=CASE WHEN excluded.amountAtomic IS NULL THEN nearHoldings.blockHeight ELSE excluded.blockHeight END,
                      verified=excluded.verified,failure=excluded.failure
                    """,arguments:[ticket.account.id,holding.reference,asset?.id,holding.amount,time,value.block.height,catalog.contains(holding.reference),holding.failure])
            }
            try db.execute(sql:"UPDATE nearSync SET inventory=?,observedAt=?,blockHeight=?,failure=NULL WHERE accountID=?",arguments:[try JSONEncoder().encode(value),time,value.block.height,ticket.account.id])
            for row in try Row.fetchAll(db,sql:"SELECT detail FROM nearEvents WHERE accountID=? AND unresolved=1",arguments:[ticket.account.id]) {
                try Self.projectNear(JSONDecoder().decode(NearEvent.self,from:row["detail"]),ticket:ticket,db:db)
            }
        }
    }
    public func nearHistoryWork(_ ticket:NearSyncTicket, stream:String) async throws -> NearHistoryCursor? {
        try await pool.read { db in
            try Self.validateNear(ticket,db:db)
            return try NearHistoryCursor.fetchOne(db,sql:"SELECT * FROM nearHistoryCursors WHERE accountID=? AND stream=? AND complete=0 ORDER BY lane DESC LIMIT 1",arguments:[ticket.account.id,stream])
        }
    }
    private static func projectNear(_ event:NearEvent, ticket:NearSyncTicket, db:Database) throws {
        guard event.owner == ticket.account.address else { throw NearError.wrongOwner }
        var unresolved = true
        if let reference = event.reference, let token = try nearToken(reference,input:event.token,db:db) {
            let asset = try nearAsset(token,db:db)
            let hash = event.hash ?? event.receipt
            let id = event.hash.map{"near:"+$0} ?? "near:receipt:"+event.receipt
            if try TransactionRecord.fetchOne(db,key:id) == nil {
                try TransactionRecord(id:id,networkID:"near",hash:hash,state:"confirmed",blockHeight:event.blockHeight,timestamp:event.timestamp,updatedAt:Date().timeIntervalSince1970).insert(db)
            }
            let negative = event.amount.hasPrefix("-"), amount = negative ? String(event.amount.dropFirst()):event.amount
            _ = try AtomicAmount(amount)
            let direction = event.counterparty == event.owner ? "self":negative ? "outgoing":"incoming"
            try ActivityRecord(id:ticket.account.id+":near:event:"+event.id,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"near",transactionID:id,assetID:asset.id,direction:direction,amountAtomic:amount,counterparty:event.counterparty ?? "",timestamp:event.timestamp).upsert(db)
            if reference == "native" { try db.execute(sql:"DELETE FROM activity WHERE id=?",arguments:[ticket.account.id+":near:execution:"+hash]) }
            unresolved = false
        }
        try db.execute(sql:"INSERT OR REPLACE INTO nearEvents(accountID,eventID,hash,blockHeight,detail,unresolved) VALUES(?,?,?,?,?,?)",arguments:[ticket.account.id,event.id,event.hash,event.blockHeight,try JSONEncoder().encode(event),unresolved])
    }
    public func commitNearPage(_ page:NearHistoryPage, cursor:NearHistoryCursor, ticket:NearSyncTicket) async throws {
        guard cursor.accountID == ticket.account.id, ["transfers","transactions"].contains(cursor.stream),
              cursor.stream == "transfers" ? page.executions.isEmpty : page.events.isEmpty,
              page.next == nil || (page.next != cursor.beforeCursor && !page.ids.isEmpty), page.head == page.ids.first,
              Set(page.ids).count == page.ids.count else { throw NearError.paginationLoop }
        try await pool.write { db in
            try Self.validateNear(ticket,db:db)
            guard try NearHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            for execution in page.executions {
                guard execution.owner == ticket.account.address else { throw NearError.wrongOwner }
                let id = "near:"+execution.hash
                try TransactionRecord(id:id,networkID:"near",hash:execution.hash,state:execution.failed ? "failed":"confirmed",blockHeight:execution.blockHeight,timestamp:execution.timestamp,feeAtomic:execution.fee,updatedAt:Date().timeIntervalSince1970).upsert(db)
                try db.execute(sql:"INSERT OR REPLACE INTO nearTransactions(accountID,hash,detail) VALUES(?,?,?)",arguments:[ticket.account.id,execution.hash,try JSONEncoder().encode(execution)])
                let hasNative = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM activity a JOIN assets t ON t.id=a.assetID WHERE a.accountID=? AND a.transactionID=? AND t.reference='native')",arguments:[ticket.account.id,id]) ?? false
                if !hasNative {
                    let native = try Self.nearAsset(.native,db:db)
                    try ActivityRecord(id:ticket.account.id+":near:execution:"+execution.hash,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"near",transactionID:id,assetID:native.id,direction:"self",amountAtomic:"0",counterparty:"",timestamp:execution.timestamp).upsert(db)
                }
            }
            for event in page.events { try Self.projectNear(event,ticket:ticket,db:db) }
            try db.execute(sql:"INSERT OR REPLACE INTO nearPages(accountID,pageKey,raw) VALUES(?,?,?)",arguments:[ticket.account.id,cursor.stream+":"+(cursor.beforeCursor ?? "first:"+(page.head ?? "empty")),page.raw])
            var backlog = try NearHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":"backfill"])
            if cursor.lane == "recent", cursor.stopID == nil, cursor.beforeCursor == nil, var initial = backlog, initial.headID == nil, initial.beforeCursor == nil, !initial.complete {
                initial.headID = page.head; initial.beforeCursor = page.next; initial.complete = page.next == nil; try initial.update(db); backlog = initial
            }
            var next = cursor; next.headID = cursor.headID ?? page.head ?? cursor.stopID; next.beforeCursor = page.next
            let reached = cursor.stopID.map{page.ids.contains($0)} ?? false
            next.complete = page.next == nil || (cursor.lane == "recent" && (reached || cursor.stopID == nil && backlog?.complete == false))
            try next.update(db)
        }
    }
}
