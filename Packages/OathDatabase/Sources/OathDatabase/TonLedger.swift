import Foundation
import GRDB
import OathAnkr

public struct TonSyncTicket: Sendable { public let account: AccountRecord; public let runID: String }
public struct TonHistoryCursor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tonHistoryCursors"
    public let accountID: String
    public let stream: String
    public let lane: String
    public var beforeLT: Int64?
    public var stopLT: Int64?
    public var headLT: Int64?
    public var complete: Bool
}
extension OathDatabase {
    public func beginTonSync(accountID: String) async throws -> TonSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "ton" else { throw StoreError.missingRecord }
            _ = try TonIdentity.raw(account.address)
            let run = UUID().uuidString
            try db.execute(sql:"INSERT INTO tonSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL",arguments:[accountID,run])
            for stream in TonStream.allCases {
                for lane in ["recent","backfill"] {
                    var cursor = try TonHistoryCursor.fetchOne(db,key:["accountID":accountID,"stream":stream.rawValue,"lane":lane]) ?? .init(accountID:accountID,stream:stream.rawValue,lane:lane,complete:false)
                    if lane == "recent", cursor.complete {
                        cursor.stopLT = cursor.headLT; cursor.beforeLT = nil; cursor.headLT = nil; cursor.complete = false
                    }
                    try cursor.upsert(db)
                }
            }
            return .init(account:account,runID:run)
        }
    }
    static func validateTon(_ ticket: TonSyncTicket, db: Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account,
              try String.fetchOne(db,sql:"SELECT runID FROM tonSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failTonSync(_ ticket: TonSyncTicket, history: Bool, code: String) async throws {
        try await pool.write { db in
            try Self.validateTon(ticket,db:db)
            try db.execute(sql:"UPDATE tonSync SET \(history ? "historyFailure" : "failure")=? WHERE accountID=?",arguments:[code,ticket.account.id])
        }
    }
    public func tonInventory(accountID: String) async throws -> TonInventory? {
        try await pool.read { db in
            guard let raw = try Data.fetchOne(db,sql:"SELECT inventory FROM tonSync WHERE accountID=?",arguments:[accountID]) else { return nil }
            return try JSONDecoder().decode(TonInventory.self,from:raw)
        }
    }
    static func tonAsset(_ token: TonToken, db: Database) throws -> AssetRecord {
        let reference = token.reference == "native" ? "native" : try TonIdentity.raw(token.reference)
        guard reference == token.reference, (0...255).contains(token.decimals) else { throw TonError.malformed }
        if reference != "native" {
            let metadata = MarketCacheEntry(key:"ton.token."+reference,source:"TonAPI",payload:try JSONEncoder().encode(token),fetchedAt:Date().timeIntervalSince1970)
            try metadata.upsert(db)
            try HistorySafety.ingestCatalog(metadata, db: db)
        }
        if var asset = try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='ton' AND reference=?",arguments:[reference]) {
            guard asset.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            asset.name = token.name; asset.symbol = token.symbol; asset.logo = token.logo ?? asset.logo
            try asset.update(db); return asset
        }
        let asset = AssetRecord(id:"ton:"+reference,networkID:"ton",reference:reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo)
        try asset.insert(db); return asset
    }
    public func commitTonInventory(_ value: TonInventory, ticket: TonSyncTicket) async throws {
        guard value.owner == (try TonIdentity.raw(ticket.account.address)), Set(value.holdings.map{$0.token.reference}).count == value.holdings.count,
              value.holdings.filter({$0.token.reference == "native"}).count == 1 else { throw TonError.wrongOwner }
        try await pool.write { db in
            try Self.validateTon(ticket,db:db)
            let time = value.observedAt.timeIntervalSince1970
            let previous = try Double.fetchOne(db,sql:"SELECT observedAt FROM tonSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            guard time >= previous else { throw StoreError.staleSync }
            let found = Set(value.holdings.map{$0.token.reference}).union(value.failedReferences)
            if value.discoveryComplete {
                for row in try Row.fetchAll(db,sql:"SELECT h.assetID,a.reference FROM tonHoldings h JOIN assets a ON a.id=h.assetID WHERE h.accountID=?",arguments:[ticket.account.id]) {
                    let reference: String = row["reference"]
                    if !found.contains(reference) { try db.execute(sql:"UPDATE tonHoldings SET amountAtomic='0',observedAt=? WHERE accountID=? AND assetID=?",arguments:[time,ticket.account.id,row["assetID"] as String]) }
                }
            }
            for holding in value.holdings {
                _ = try AtomicAmount(holding.amount)
                let asset = try Self.tonAsset(holding.token,db:db)
                try db.execute(sql:"""
                    INSERT INTO tonHoldings(accountID,assetID,amountAtomic,observedAt,verified) VALUES(?,?,?,?,?)
                    ON CONFLICT(accountID,assetID) DO UPDATE SET amountAtomic=excluded.amountAtomic,observedAt=excluded.observedAt,verified=excluded.verified
                    """,arguments:[ticket.account.id,asset.id,holding.amount,time,holding.token.verified])
            }
            try db.execute(sql:"UPDATE tonSync SET inventory=?,observedAt=?,failure=? WHERE accountID=?",arguments:[try JSONEncoder().encode(value),time,value.discoveryComplete && value.failedReferences.isEmpty ? nil : "partialInventory",ticket.account.id])
        }
    }
    public func tonHistoryWork(_ ticket: TonSyncTicket) async throws -> [TonHistoryCursor] {
        try await pool.read { db in
            try Self.validateTon(ticket,db:db)
            let all = try TonHistoryCursor.fetchAll(db,sql:"SELECT * FROM tonHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC,stream",arguments:[ticket.account.id])
            var seen: Set<String> = []; return all.filter { seen.insert($0.stream).inserted }
        }
    }
    public func commitTonPage(_ page: TonHistoryPage, cursor: TonHistoryCursor, ticket: TonSyncTicket) async throws {
        guard cursor.accountID == ticket.account.id else { throw StoreError.staleSync }
        guard page.next == nil || (page.next! > 0 && (cursor.beforeLT == nil || page.next! < cursor.beforeLT!)) else { throw TonError.paginationLoop }
        guard page.head == page.transactions.map(\.lt).max(), page.next == nil || !page.transactions.isEmpty,
              page.transactions.allSatisfy({ $0.lt > 0 && (cursor.beforeLT == nil || $0.lt < cursor.beforeLT!) }) else { throw TonError.malformed }
        let owner = try TonIdentity.raw(ticket.account.address)
        try await pool.write { db in
            try Self.validateTon(ticket,db:db)
            guard try TonHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            let now = Date().timeIntervalSince1970
            for tx in page.transactions {
                let id = "ton:"+tx.hash
                // Native and Jetton streams can describe the same transaction.
                // A token operation must never erase its native fee/failure.
                let existing = try TransactionRecord.fetchOne(db,key:id)
                let locallyTracked = try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM sends WHERE networkID='ton' AND transactionID=? AND signedPayload IS NOT NULL)",arguments:[id]) == true
                try TransactionRecord(id:id,networkID:"ton",hash:tx.hash,state:locallyTracked ? (existing?.state ?? "pending") : tx.failed || existing?.state == "failed" ? "failed" : "confirmed",blockHeight:existing?.blockHeight,timestamp:tx.timestamp,feeAtomic:tx.fee ?? existing?.feeAtomic,updatedAt:now).upsert(db)
                try db.execute(sql:"INSERT OR REPLACE INTO tonTransactions(accountID,stream,hash,eventKey,detail) VALUES(?,?,?,?,?)",arguments:[ticket.account.id,cursor.stream,tx.hash,String(tx.events.first?.index ?? 0),try JSONEncoder().encode(tx)])
                for event in tx.events {
                    guard event.from == owner || event.to == owner else { throw TonError.wrongOwner }
                    _ = try AtomicAmount(event.amount)
                    let asset = try Self.tonAsset(event.token,db:db)
                    let direction = event.from == event.to ? "self" : event.to == owner ? "incoming" : "outgoing"
                    // Replace the local intent only when the verified chain
                    // movement agrees with its asset, amount and recipient.
                    try db.execute(sql:"DELETE FROM activity WHERE transactionID=? AND accountID=? AND assetID=? AND direction=? AND amountAtomic=? AND counterparty=? AND id IN (SELECT accountID||':'||p.messageHash||':'||a.reference FROM sends s JOIN tonSendPlans p ON p.sendID=s.id JOIN assets a ON a.id=s.assetID WHERE s.transactionID=?)",arguments:[id,ticket.account.id,asset.id,direction,event.amount,direction == "incoming" ? event.from:event.to,id])
                    let suffix = tx.hash+":"+String(event.index)
                    try ActivityRecord(id:ticket.account.id+":"+suffix,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"ton",transactionID:id,assetID:asset.id,direction:direction,amountAtomic:event.amount,counterparty:direction == "incoming" ? event.from : event.to,timestamp:tx.timestamp).upsert(db)
                    try TransferRecord(id:"ton:"+suffix,transactionID:id,networkID:"ton",assetID:asset.id,eventIndex:event.index,fromAddress:event.from,toAddress:event.to,amountAtomic:event.amount).upsert(db)
                }
            }
            try db.execute(sql:"INSERT OR REPLACE INTO tonPages(accountID,stream,pageKey,raw) VALUES(?,?,?,?)",arguments:[ticket.account.id,cursor.stream,cursor.beforeLT.map(String.init) ?? "first",page.raw])
            var backlog = try TonHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":"backfill"])
            if cursor.lane == "recent", cursor.stopLT == nil, cursor.beforeLT == nil,
               var initial = backlog, initial.headLT == nil, initial.beforeLT == nil, !initial.complete {
                // The first page already belongs to the complete history. Start
                // older-page loading at its boundary instead of fetching twice.
                initial.headLT = page.head; initial.beforeLT = page.next; initial.complete = page.next == nil
                try initial.update(db); backlog = initial
            }
            var next = cursor
            next.headLT = [cursor.headLT,page.head,cursor.stopLT].compactMap{$0}.max()
            next.beforeLT = page.next
            let reached = cursor.stopLT.map { stop in page.transactions.contains { $0.lt <= stop } } ?? false
            // A previously empty account has no high-water mark. If it later
            // gains several pages, read all of them even though its old empty
            // backfill was already complete.
            let coveredByBackfill = cursor.stopLT == nil && backlog?.complete == false
            next.complete = page.next == nil || (cursor.lane == "recent" && (coveredByBackfill || reached))
            try next.update(db)
        }
    }
}
