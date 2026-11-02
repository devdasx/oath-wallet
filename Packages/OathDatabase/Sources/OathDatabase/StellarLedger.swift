import OathDiagnostics
import Foundation
import GRDB
import OathAnkr

public struct StellarSyncTicket: Sendable { public let account:AccountRecord; public let runID:String }
public struct StellarHistoryCursor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "stellarHistoryCursors"
    public let accountID:String
    public let lane:String
    public let startLedger:Int64
    public let endLedger:Int64
    public var cursor:String?
    public var complete:Bool

}
extension OathDatabase {
    public func beginStellarSync(accountID:String, latestLedger:Int64) async throws -> StellarSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "stellar" else { throw StoreError.missingRecord }
            _ = try StellarIdentity.address(account.address)
            let run = UUID().uuidString
            try db.execute(sql:"INSERT INTO stellarSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL",arguments:[accountID,run])
            guard latestLedger > 0 else { throw StellarError.malformed }
            let recentStart = max(1,latestLedger-518_400)
            for lane in ["recent","backfill"] {
                var cursor = try StellarHistoryCursor.fetchOne(db,key:["accountID":accountID,"lane":lane])
                if cursor == nil {
                    cursor = .init(accountID:accountID,lane:lane,startLedger:lane == "recent" ? recentStart:1,
                        endLedger:lane == "recent" ? latestLedger:max(1,recentStart-1),complete:lane == "backfill" && recentStart == 1)
                } else if lane == "recent", cursor!.complete, latestLedger > cursor!.endLedger {
                    cursor = .init(accountID:accountID,lane:lane,startLedger:cursor!.endLedger+1,endLedger:latestLedger,complete:false)
                }
                try cursor!.upsert(db)
            }
            return .init(account:account,runID:run)
        }
    }
    static func validateStellar(_ ticket:StellarSyncTicket, db:Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account,
              try String.fetchOne(db,sql:"SELECT runID FROM stellarSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failStellarSync(_ ticket:StellarSyncTicket, history:Bool, code:String) async throws {
        try await pool.write { db in
            try Self.validateStellar(ticket,db:db)
            try db.execute(sql:"UPDATE stellarSync SET \(history ? "historyFailure":"failure")=? WHERE accountID=?",arguments:[code,ticket.account.id])
        }
    }
    public func stellarInventory(accountID:String) async throws -> StellarInventory? {
        try await pool.read { db in
            guard let raw = try Data.fetchOne(db,sql:"SELECT inventory FROM stellarSync WHERE accountID=?",arguments:[accountID]) else { return nil }
            return try JSONDecoder().decode(StellarInventory.self,from:raw)
        }
    }
    private static func stellarToken(_ reference:String, input:StellarToken?, db:Database) throws -> StellarToken? {
        if reference == "native" { return .native }
        if let input {
            guard input.reference == reference, (0...255).contains(input.decimals) else { throw StellarError.malformed }
            return input
        }
        guard let saved = try MarketCacheEntry.fetchOne(db,key:"stellar.token."+reference) else { return nil }
        let token = try JSONDecoder().decode(StellarToken.self,from:saved.payload)
        guard token.reference == reference else { throw StoreError.conflictingIdentity }; return token
    }
    public func saveStellarMetadata(_ tokens:[StellarToken],ticket:StellarSyncTicket) async throws {
        try await pool.write { db in
            try Self.validateStellar(ticket,db:db)
            for token in tokens { _ = try Self.stellarAsset(token,db:db) }
        }
    }
    private static func stellarAsset(_ token:StellarToken, db:Database) throws -> AssetRecord {
        guard try StellarIdentity.reference(token.reference) == token.reference else { throw StoreError.conflictingIdentity }
        var metadata = token
        if token.name == token.symbol, let saved = try MarketCacheEntry.fetchOne(db,key:"stellar.token."+token.reference),
           let richer = OathDiagnostics.attempt("decode_cached_token", body: { try JSONDecoder().decode(StellarToken.self, from: saved.payload) }), richer.reference == token.reference, richer.decimals == token.decimals, richer.name != richer.symbol { metadata = richer }
        try MarketCacheEntry(key:"stellar.token."+token.reference,source:"Stellar metadata",payload:try JSONEncoder().encode(metadata),fetchedAt:Date().timeIntervalSince1970).upsert(db)
        if var asset = try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='stellar' AND reference=?",arguments:[token.reference]) {
            guard asset.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            if token.name != token.symbol || asset.name == asset.symbol { asset.name = token.name; asset.symbol = token.symbol }; asset.logo = token.logo ?? asset.logo
            try asset.update(db); return asset
        }
        let asset = AssetRecord(id:"stellar:"+token.reference,networkID:"stellar",reference:token.reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo)
        try asset.insert(db); return asset
    }
    public func commitStellarInventory(_ value:StellarInventory, ticket:StellarSyncTicket, catalog:StellarCatalog) async throws {
        guard value.observedAt.timeIntervalSince1970.isFinite, value.ledger.height >= 0, value.owner == (try StellarIdentity.address(ticket.account.address)),
              Set(value.holdings.map(\.reference)).count == value.holdings.count,
              value.holdings.filter({$0.reference == "native"}).count == 1 else { throw StellarError.wrongOwner }
        try await pool.write { db in
            try Self.validateStellar(ticket,db:db)
            let time = value.observedAt.timeIntervalSince1970
            let previous = try Double.fetchOne(db,sql:"SELECT observedAt FROM stellarSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            let checkpoint = try Int64.fetchOne(db,sql:"SELECT checkpoint FROM stellarSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            guard time >= previous, value.ledger.height >= checkpoint else { throw StoreError.staleSync }
            // A complete combined inventory is the only operation that clears
            // spent tokens. Unknown metadata still keeps its exact raw balance.
            try db.execute(sql:"UPDATE stellarHoldings SET amountAtomic='0',observedAt=?,checkpoint=? WHERE accountID=?",arguments:[time,value.ledger.height,ticket.account.id])
            for holding in value.holdings {
                guard try StellarIdentity.reference(holding.reference) == holding.reference else { throw StoreError.conflictingIdentity }
                _ = try AtomicAmount(holding.amount)
                let token = try Self.stellarToken(holding.reference,input:catalog.tokens[holding.reference] ?? holding.token,db:db)
                let asset = try token.map{try Self.stellarAsset($0,db:db)}
                try db.execute(sql:"""
                    INSERT INTO stellarHoldings(accountID,reference,assetID,amountAtomic,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET assetID=excluded.assetID,amountAtomic=excluded.amountAtomic,observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=excluded.verified
                    """,arguments:[ticket.account.id,holding.reference,asset?.id,holding.amount,time,value.ledger.height,catalog.contains(holding.reference) || value.verified.contains(holding.reference)])
            }
            try db.execute(sql:"UPDATE stellarSync SET inventory=?,observedAt=?,checkpoint=?,failure=NULL WHERE accountID=?",arguments:[try JSONEncoder().encode(value),time,value.ledger.height,ticket.account.id])
            // Metadata may have become available since a historical transfer.
            // Re-project saved receipts without another history request.
            for row in try Row.fetchAll(db,sql:"SELECT hash FROM stellarTransactions WHERE accountID=? AND unresolved=1",arguments:[ticket.account.id]) {
                try Self.projectStellar(row["hash"],ticket:ticket,db:db)
            }
        }
    }
    public func stellarHistoryWork(_ ticket:StellarSyncTicket) async throws -> [StellarHistoryCursor] {
        try await pool.read { db in
            try Self.validateStellar(ticket,db:db)
            return try StellarHistoryCursor.fetchAll(db,sql:"SELECT * FROM stellarHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC",arguments:[ticket.account.id])
        }
    }
    private static func projectStellar(_ hash:String,ticket:StellarSyncTicket,db:Database) throws {
        let events = try Data.fetchAll(db,sql:"SELECT detail FROM stellarEvents WHERE accountID=? AND hash=? ORDER BY id",arguments:[ticket.account.id,hash]).map{try JSONDecoder().decode(StellarEvent.self,from:$0)}
        guard let first = events.first else { return }
        var sums:[String:String] = [:], metadata:[String:StellarToken] = [:], fee = "0"
        for event in events {
            _ = try AtomicAmount(event.kind == "fee" && event.amount.hasPrefix("-") ? String(event.amount.dropFirst()):event.amount)
            if let token = event.token { metadata[event.reference] = token }
            if event.kind == "fee" { fee = StellarIdentity.sum(fee,event.amount); continue }
            guard event.successful else { continue }
            let delta = event.direction == "self" ? "0":event.direction == "outgoing" ? "-"+event.amount:event.amount
            sums[event.reference] = StellarIdentity.sum(sums[event.reference] ?? "0",delta)
        }
        if sums.isEmpty { sums["native"] = "0" }
        guard !fee.hasPrefix("-") else { throw StellarError.malformed }
        let id = "stellar:"+hash, now = Date().timeIntervalSince1970
        let previous = try TransactionRecord.fetchOne(db,key:id)
        let knownFee = events.contains(where:{$0.kind == "fee"}) ? fee:previous?.feeAtomic
        try TransactionRecord(id:id,networkID:"stellar",hash:hash,state:events.contains(where:{$0.successful}) ? "confirmed":"failed",blockHeight:first.checkpoint,timestamp:first.timestamp,feeAtomic:knownFee,updatedAt:now).upsert(db)
        // Rebuild this account's projection atomically. A fee-only first page
        // must not leave a synthetic native row after token events arrive.
        try db.execute(sql:"DELETE FROM activity WHERE accountID=? AND transactionID=?",arguments:[ticket.account.id,id])
        var unresolved = false
        let peers = Set(events.compactMap(\.counterparty)), peer = peers.count == 1 ? peers.first:nil
        for (reference,amount) in sums {
            guard let token = try stellarToken(reference,input:metadata[reference],db:db) else { unresolved = true; continue }
            let asset = try stellarAsset(token,db:db)
            try ActivityRecord(id:ticket.account.id+":"+hash+":"+reference,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"stellar",transactionID:id,assetID:asset.id,
                direction:amount == "0" ? "self":amount.hasPrefix("-") ? "outgoing":"incoming",amountAtomic:amount.hasPrefix("-") ? String(amount.dropFirst()):amount,counterparty:peer ?? "",timestamp:first.timestamp).upsert(db)
        }
        try db.execute(sql:"INSERT OR REPLACE INTO stellarTransactions(accountID,hash,checkpoint,detail,unresolved) VALUES(?,?,?,?,?)",arguments:[ticket.account.id,hash,first.checkpoint,try JSONEncoder().encode(events),unresolved])
    }
    public func commitStellarPage(_ page:StellarEventPage,cursor:StellarHistoryCursor,ticket:StellarSyncTicket) async throws {
        guard cursor.accountID == ticket.account.id, cursor.startLedger == page.startLedger, cursor.endLedger == page.endLedger,
              page.events.allSatisfy({$0.checkpoint >= page.startLedger && $0.checkpoint <= page.endLedger}),
              page.complete || (page.next != nil && page.next != cursor.cursor), Set(page.events.map(\.id)).count == page.events.count else { throw StellarError.paginationLoop }
        try await pool.write { db in
            try Self.validateStellar(ticket,db:db)
            guard try StellarHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            for event in page.events {
                try db.execute(sql:"INSERT OR REPLACE INTO stellarEvents(accountID,id,hash,detail) VALUES(?,?,?,?)",arguments:[ticket.account.id,event.id,event.hash,try JSONEncoder().encode(event)])
            }
            for hash in Set(page.events.map(\.hash)) { try Self.projectStellar(hash,ticket:ticket,db:db) }
            try db.execute(sql:"INSERT OR REPLACE INTO stellarPages(accountID,pageKey,raw) VALUES(?,?,?)",arguments:[ticket.account.id,cursor.lane+":"+String(cursor.startLedger)+":"+(cursor.cursor ?? "first"),page.raw])
            var next = cursor; next.cursor = page.next; next.complete = page.complete; try next.update(db)
        }
    }
}
