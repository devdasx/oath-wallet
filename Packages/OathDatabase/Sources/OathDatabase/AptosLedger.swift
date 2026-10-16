import Foundation
import GRDB
import OathAnkr

public struct AptosSyncTicket: Sendable { public let account: AccountRecord; public let runID: String }
public struct AptosHistoryCursor: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "aptosHistoryCursors"
    public let accountID: String
    public let stream: String
    public let lane: String
    public var beforeVersion: Int64?
    public var stopVersion: Int64?
    public var headVersion: Int64?
    public var complete: Bool
}
extension OathDatabase {
    public func beginAptosSync(accountID: String) async throws -> AptosSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.networkID == "aptos" else { throw StoreError.missingRecord }
            _ = try AptosIdentity.address(account.address)
            let run = UUID().uuidString
            try db.execute(sql:"INSERT INTO aptosSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL,historyFailure=NULL",arguments:[accountID,run])
            for stream in ["account"] {
                for lane in ["recent","backfill"] {
                    var cursor = try AptosHistoryCursor.fetchOne(db,key:["accountID":accountID,"stream":stream,"lane":lane]) ?? .init(accountID:accountID,stream:stream,lane:lane,complete:false)
                    if lane == "recent", cursor.complete {
                        cursor.stopVersion = cursor.headVersion; cursor.beforeVersion = nil; cursor.headVersion = nil; cursor.complete = false
                    }
                    try cursor.upsert(db)
                }
            }
            return .init(account:account,runID:run)
        }
    }
    static func validateAptos(_ ticket: AptosSyncTicket, db: Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account,
              try String.fetchOne(db,sql:"SELECT runID FROM aptosSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func failAptosSync(_ ticket: AptosSyncTicket, history: Bool, code: String) async throws {
        try await pool.write { db in
            try Self.validateAptos(ticket,db:db)
            try db.execute(sql:"UPDATE aptosSync SET \(history ? "historyFailure" : "failure")=? WHERE accountID=?",arguments:[code,ticket.account.id])
        }
    }
    public func aptosInventory(accountID: String) async throws -> AptosInventory? {
        try await pool.read { db in
            guard let raw = try Data.fetchOne(db,sql:"SELECT inventory FROM aptosSync WHERE accountID=?",arguments:[accountID]) else { return nil }
            return try JSONDecoder().decode(AptosInventory.self,from:raw)
        }
    }
    static func aptosReference(_ input:String, catalog:AptosCatalog, db:Database) throws -> String {
        let reference=catalog.canonical(input)
        guard let saved=try MarketCacheEntry.fetchOne(db,key:"aptos.alias."+reference),
              let alias=String(data:saved.payload,encoding:.utf8) else {return reference}
        guard try AptosIdentity.reference(alias)==alias else {throw StoreError.conflictingIdentity}
        return catalog.canonical(alias)
    }
    static func aptosAsset(_ input: AptosToken, catalog: AptosCatalog, db: Database) throws -> AssetRecord {
        let enriched=catalog.enrich(input)
        let token=enriched.replacingReference(try aptosReference(enriched.reference,catalog:catalog,db:db))
        let reference = try AptosIdentity.reference(token.reference)
        guard reference == token.reference, (0...255).contains(token.decimals) else { throw AptosError.malformed }
        if token.verified {
            try HistorySafety.trust(networkID: "aptos", reference: reference, decimals: token.decimals,
                source: "verified.history.catalog", observedAt: Date().timeIntervalSince1970, db: db)
        }
        if reference != "native" {
            try MarketCacheEntry(key:"aptos.token."+reference,source:"Aptos / Panora",payload:try JSONEncoder().encode(token),fetchedAt:Date().timeIntervalSince1970).upsert(db)
        }
        if var asset = try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='aptos' AND reference=?",arguments:[reference]) {
            guard asset.decimals == token.decimals else { throw StoreError.conflictingIdentity }
            asset.name = token.name; asset.symbol = token.symbol; asset.logo = token.logo ?? asset.logo
            try asset.update(db); return asset
        }
        let asset = AssetRecord(id:"aptos:"+reference,networkID:"aptos",reference:reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo)
        try asset.insert(db); return asset
    }
    public func commitAptosInventory(_ value: AptosInventory, ticket: AptosSyncTicket, catalog: AptosCatalog) async throws {
        guard value.owner == (try AptosIdentity.address(ticket.account.address)), Set(value.holdings.map{$0.token.reference}).count == value.holdings.count,
              value.holdings.filter({$0.token.reference == "native"}).count == 1 else { throw AptosError.wrongOwner }
        // Paired Coin/FA identities must have been combined at the node layer.
        // Never silently overwrite one with another after catalog aliasing.
        guard Set(value.holdings.map{catalog.canonical($0.token.reference)}).count == value.holdings.count else { throw StoreError.conflictingIdentity }
        try await pool.write { db in
            try Self.validateAptos(ticket,db:db)
            let time = value.observedAt.timeIntervalSince1970
            let previous = try Double.fetchOne(db,sql:"SELECT observedAt FROM aptosSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            let version = try Int64.fetchOne(db,sql:"SELECT ledgerVersion FROM aptosSync WHERE accountID=?",arguments:[ticket.account.id]) ?? 0
            guard time >= previous, value.ledgerVersion >= version else { throw StoreError.staleSync }
            // Retain public migration identities after a token is spent, so
            // older Coin events and newer FA events use the same asset history.
            for (fa,coin) in value.pairedReferences ?? [:] where fa != coin {
                guard try AptosIdentity.reference(fa)==fa,try AptosIdentity.reference(coin)==coin,
                      !fa.contains("::"),coin.contains("::") else {throw StoreError.conflictingIdentity}
                let key="aptos.alias."+fa
                if let existing=try MarketCacheEntry.fetchOne(db,key:key),existing.payload != Data(coin.utf8) {throw StoreError.conflictingIdentity}
                try MarketCacheEntry(key:key,source:"Aptos Coin/FA mapping",payload:Data(coin.utf8),fetchedAt:time).upsert(db)
            }
            let references=try value.holdings.map{try Self.aptosReference($0.token.reference,catalog:catalog,db:db)}
            guard Set(references).count==references.count else {throw StoreError.conflictingIdentity}
            let failed=Set(try value.failedReferences.map{try Self.aptosReference($0,catalog:catalog,db:db)})
            let found=Set(references).union(failed)
            if value.discoveryComplete {
                for row in try Row.fetchAll(db,sql:"SELECT h.assetID,a.reference FROM aptosHoldings h JOIN assets a ON a.id=h.assetID WHERE h.accountID=?",arguments:[ticket.account.id]) {
                    let reference: String = row["reference"]
                    if !found.contains(reference) { try db.execute(sql:"UPDATE aptosHoldings SET amountAtomic='0',observedAt=? WHERE accountID=? AND assetID=?",arguments:[time,ticket.account.id,row["assetID"] as String]) }
                }
            }
            for holding in value.holdings where !failed.contains(try Self.aptosReference(holding.token.reference,catalog:catalog,db:db)) {
                _ = try AtomicAmount(holding.amount)
                let asset = try Self.aptosAsset(holding.token,catalog:catalog,db:db)
                try db.execute(sql:"""
                    INSERT INTO aptosHoldings(accountID,assetID,amountAtomic,observedAt,verified) VALUES(?,?,?,?,?)
                    ON CONFLICT(accountID,assetID) DO UPDATE SET amountAtomic=excluded.amountAtomic,observedAt=excluded.observedAt,verified=excluded.verified
                    """,arguments:[ticket.account.id,asset.id,holding.amount,time,catalog.enrich(holding.token).verified])
            }
            try db.execute(sql:"UPDATE aptosSync SET inventory=?,observedAt=?,ledgerVersion=?,failure=? WHERE accountID=?",arguments:[try JSONEncoder().encode(value),time,value.ledgerVersion,value.discoveryComplete && value.failedReferences.isEmpty ? nil : (value.discoveryFailure ?? "partialInventory"),ticket.account.id])
        }
    }
    public func aptosHistoryWork(_ ticket: AptosSyncTicket) async throws -> [AptosHistoryCursor] {
        try await pool.read { db in
            try Self.validateAptos(ticket,db:db)
            let all = try AptosHistoryCursor.fetchAll(db,sql:"SELECT * FROM aptosHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC,stream",arguments:[ticket.account.id])
            var seen: Set<String> = []; return all.filter { seen.insert($0.stream).inserted }
        }
    }
    public func commitAptosPage(_ page: AptosHistoryPage, cursor: AptosHistoryCursor, ticket: AptosSyncTicket, catalog: AptosCatalog) async throws {
        guard cursor.accountID == ticket.account.id else { throw StoreError.staleSync }
        guard page.next == nil || (page.next! > 0 && (cursor.beforeVersion == nil || page.next! < cursor.beforeVersion!)) else { throw AptosError.paginationLoop }
        guard page.head == page.transactions.map(\.version).max(), page.next == nil || !page.transactions.isEmpty,
              page.transactions.allSatisfy({ $0.version > 0 && (cursor.beforeVersion == nil || $0.version < cursor.beforeVersion!) }) else { throw AptosError.malformed }
        let owner = try AptosIdentity.address(ticket.account.address)
        try await pool.write { db in
            try Self.validateAptos(ticket,db:db)
            guard try AptosHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":cursor.lane]) == cursor else { throw StoreError.staleSync }
            let now = Date().timeIntervalSince1970
            for tx in page.transactions {
                let id = "aptos:"+tx.hash
                try TransactionRecord(id:id,networkID:"aptos",hash:tx.hash,state:tx.failed ? "failed" : "confirmed",blockHeight:tx.version,timestamp:tx.timestamp,feeAtomic:tx.fee,updatedAt:now).upsert(db)
                try db.execute(sql:"INSERT OR REPLACE INTO aptosTransactions(accountID,hash,version,detail) VALUES(?,?,?,?)",arguments:[ticket.account.id,tx.hash,tx.version,try JSONEncoder().encode(tx)])
                // A locally signed transfer already has an exact payment intent.
                // Preserve its recipient and stable activity identity when indexer
                // events arrive; raw per-event receipt data remains stored above.
                let local=try SendRecord.fetchOne(db,sql:"SELECT * FROM sends WHERE accountID=? AND transactionID=? AND networkID='aptos' AND signedPayload IS NOT NULL LIMIT 1",arguments:[ticket.account.id,id])
                if let local,let asset=try AssetRecord.fetchOne(db,key:local.assetID) {
                    try ActivityRecord(id:ticket.account.id+":"+tx.hash+":"+asset.reference,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"aptos",transactionID:id,assetID:local.assetID,direction:"outgoing",amountAtomic:local.amountAtomic,counterparty:local.recipient,timestamp:tx.timestamp).upsert(db)
                }
                for event in tx.events {
                    guard event.owner == owner, ["incoming","outgoing","self"].contains(event.direction) else { throw AptosError.wrongOwner }
                    _ = try AtomicAmount(event.amount)
                    let asset = try Self.aptosAsset(event.token,catalog:catalog,db:db)
                    if let local,tx.failed || (event.direction=="outgoing" && asset.id==local.assetID) { continue }
                    let suffix = tx.hash+":"+String(event.index)
                    // FA deposit/withdraw events do not reliably identify a
                    // counterparty (swaps and multi-agent calls can have many).
                    // Keep the complete receipt without inventing one.
                    try ActivityRecord(id:ticket.account.id+":"+suffix,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"aptos",transactionID:id,assetID:asset.id,direction:event.direction,amountAtomic:event.amount,counterparty:"",timestamp:tx.timestamp).upsert(db)
                }
            }
            try db.execute(sql:"INSERT OR REPLACE INTO aptosPages(accountID,stream,pageKey,raw) VALUES(?,?,?,?)",arguments:[ticket.account.id,cursor.stream,cursor.beforeVersion.map(String.init) ?? "first",page.raw])
            var backlog = try AptosHistoryCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":"backfill"])
            if cursor.lane == "recent", cursor.stopVersion == nil, cursor.beforeVersion == nil,
               var initial = backlog, initial.headVersion == nil, initial.beforeVersion == nil, !initial.complete {
                // The first page already belongs to the complete history. Start
                // older-page loading at its boundary instead of fetching twice.
                initial.headVersion = page.head; initial.beforeVersion = page.next; initial.complete = page.next == nil
                try initial.update(db); backlog = initial
            }
            var next = cursor
            next.headVersion = [cursor.headVersion,page.head,cursor.stopVersion].compactMap{$0}.max()
            next.beforeVersion = page.next
            let reached = cursor.stopVersion.map { stop in page.transactions.contains { $0.version <= stop } } ?? false
            // A previously empty account has no high-water mark. If it later
            // gains several pages, read all of them even though its old empty
            // backfill was already complete.
            let coveredByBackfill = cursor.stopVersion == nil && backlog?.complete == false
            next.complete = page.next == nil || (cursor.lane == "recent" && (coveredByBackfill || reached))
            try next.update(db)
        }
    }
}
