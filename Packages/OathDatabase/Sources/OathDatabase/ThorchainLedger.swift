import Foundation
import GRDB
import OathAnkr
import OathDiagnostics

/// Static rejection stages only: never carry account identities, SQL, balances,
/// timestamps, cursor contents or bindings into diagnostics.
private enum ThorchainSyncRejection: String, Error {
    case accountChanged = "account_changed"
    case walletUnavailable = "wallet_unavailable"
    case generationChanged = "generation_changed"
    case olderObservation = "older_observation"
    case lowerHeight = "lower_height"
    case historyCursorChanged = "history_cursor_changed"
    case historyComplete = "history_complete"
}

public struct ThorchainSyncTicket:Sendable {
    public let account:AccountRecord
    public let runID:String
    public let minimumHeight:Int64
}
public struct ThorchainCursor:Codable,Sendable,Equatable,FetchableRecord,PersistableRecord {
    public static let databaseTableName="thorchainHistory"
    public let accountID:String, stream:String, lane:String
    public var height:Int64, lowerHeight:Int64, page:Int, complete:Bool
}
extension OathDatabase {
    /// Report after SQLite unwinds/rolls back, on the caller's task so its
    /// operation ID survives the database queue hop. Public error semantics
    /// stay unchanged; unexpected storage errors propagate without relabeling.
    private func thorchainWrite<T: Sendable>(_ updates: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do { return try await pool.write(updates) }
        catch let rejection as ThorchainSyncRejection {
            // Already-observed lifecycle teardown is not a new app failure.
            if !Task.isCancelled {
                OathDiagnostics.record(StoreError.staleSync, component: "database", operation: "thorchain_sync_guard",
                    context: ["chain": "thorchain", "stage": rejection.rawValue])
            }
            throw StoreError.staleSync
        }
    }
    public func beginThorchainSync(accountID:String) async throws -> ThorchainSyncTicket {
        try await pool.write { db in
            guard let account=try AccountRecord.fetchOne(db,key:accountID), account.networkID == "thorchain",
                  let wallet=try WalletRecord.fetchOne(db,key:account.walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
            _ = try ThorchainIdentity.address(account.address)
            let minimumHeight = try Int64.fetchOne(db, sql:"SELECT height FROM thorchainSync WHERE accountID=?", arguments:[accountID]) ?? 1
            guard minimumHeight > 0 else { throw StoreError.invalidValue("height") }
            let run=UUID().uuidString
            try db.execute(sql:"INSERT INTO thorchainSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID",arguments:[accountID,run])
            return .init(account:account,runID:run,minimumHeight:minimumHeight)
        }
    }
    private static func validateThorchain(_ ticket:ThorchainSyncTicket, db:Database) throws {
        guard try AccountRecord.fetchOne(db,key:ticket.account.id) == ticket.account else { throw ThorchainSyncRejection.accountChanged }
        guard let wallet=try WalletRecord.fetchOne(db,key:ticket.account.walletID), wallet.deletedAt == nil else { throw ThorchainSyncRejection.walletUnavailable }
        guard try String.fetchOne(db,sql:"SELECT runID FROM thorchainSync WHERE accountID=?",arguments:[ticket.account.id]) == ticket.runID else { throw ThorchainSyncRejection.generationChanged }
    }
    private static func validateThorchainCatalog(_ catalog: ThorchainCatalog) throws {
        let time = catalog.observedAt.timeIntervalSince1970
        guard time.isFinite, time > 0, catalog.tokens.count <= 10_000, catalog.prices.count <= 10_000 else {
            throw StoreError.invalidValue("THORChain catalog")
        }
        for (reference, token) in catalog.tokens {
            guard try ThorchainIdentity.reference(reference) == reference, token.reference == reference,
                  (0...255).contains(token.decimals) else { throw StoreError.conflictingIdentity }
        }
        for (reference, price) in catalog.prices {
            guard try ThorchainIdentity.reference(reference) == reference else { throw StoreError.conflictingIdentity }
            try Validation.price(price)
        }
    }

    /// Balance/history requests capture a catalog before awaiting the network.
    /// Resolve it again inside their write transaction, so an older response
    /// cannot undo metadata published by another wallet in the meantime.
    private static func newerThorchainCatalog(than catalog: ThorchainCatalog, db: Database) throws -> ThorchainCatalog? {
        guard let entry = try MarketCacheEntry.fetchOne(db, key: "thorchain.catalog"),
              entry.fetchedAt >= catalog.observedAt.timeIntervalSince1970,
              entry.payload.count <= 2_000_000,
              let saved = OathDiagnostics.attempt("decode_cached_catalog", body: { try JSONDecoder().decode(ThorchainCatalog.self, from: entry.payload) }),
              saved.observedAt.timeIntervalSince1970 == entry.fetchedAt,
              OathDiagnostics.attempt("validate_cached_catalog", body: { try validateThorchainCatalog(saved) }) != nil else { return nil }
        // An undecodable/invalid optional cache is a miss, not a new failure.
        // Database read errors still propagate to the shared diagnostics boundary.
        return saved
    }
    static func thorchainAsset(_ ref:String, catalog:ThorchainCatalog, db:Database) throws -> AssetRecord? {
        _ = try ThorchainIdentity.reference(ref)
        let token=catalog.token(ref)
        guard token.reference == ref, (0...255).contains(token.decimals) else { throw StoreError.conflictingIdentity }
        let existing=try AssetRecord.fetchOne(db,sql:"SELECT * FROM assets WHERE networkID='thorchain' AND reference=?",arguments:[ref])
        // TokenFactory assets may register six or other display decimals.
        // Preserve unknown atomic quantities until metadata arrives; never
        // briefly display a guessed 8-decimal balance during a first refresh.
        guard existing != nil || catalog.tokens[ref] != nil || ThorchainIdentity.hasProtocolDecimals(ref) else { return nil }
        var asset = existing ?? .init(id:"thorchain:"+ref,networkID:"thorchain",reference:ref,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:ref == "native" ? "network-thorchain":nil)
        if catalog.tokens[ref] != nil { asset.name=token.name; asset.symbol=token.symbol; asset.decimals=token.decimals }
        try asset.upsert(db)
        if ref == "tcy" || ref == "x/ruji" || catalog.prices[ref] != nil {
            try HistorySafety.trust(networkID:"thorchain",reference:ref,decimals:asset.decimals,source:"thorchain.market",observedAt:catalog.observedAt.timeIntervalSince1970,db:db)
        }
        return asset
    }
    public func commitThorchainInventory(_ inventory:ThorchainInventory, ticket:ThorchainSyncTicket, catalog:ThorchainCatalog) async throws {
        guard inventory.owner == ticket.account.address, inventory.holdings.count <= 10_000,
              inventory.holdings.contains(where:{$0.reference == "native"}),
              Set(inventory.holdings.map(\.reference)).count == inventory.holdings.count else { throw StoreError.conflictingIdentity }
        try await thorchainWrite { db in
            try Self.validateThorchain(ticket,db:db)
            let catalog = try Self.newerThorchainCatalog(than: catalog, db: db) ?? catalog
            let time=inventory.observedAt.timeIntervalSince1970
            guard time.isFinite else { throw StoreError.invalidValue("timestamp") }
            if let old=try Double.fetchOne(db,sql:"SELECT observedAt FROM thorchainSync WHERE accountID=?",arguments:[ticket.account.id]), old>time { throw ThorchainSyncRejection.olderObservation }
            if let height=inventory.height {
                guard height>0 else {throw StoreError.invalidValue("height")}
                if let old=try Int64.fetchOne(db,sql:"SELECT height FROM thorchainSync WHERE accountID=?",arguments:[ticket.account.id]),height<old {throw ThorchainSyncRejection.lowerHeight}
            }
            // Only a fully paginated, validated bank snapshot may zero balances.
            try db.execute(sql:"UPDATE balances SET amountAtomic='0',observedAt=? WHERE accountID=? AND networkID='thorchain'",arguments:[time,ticket.account.id])
            for holding in inventory.holdings {
                try Validation.amount(holding.amount)
                guard let asset=try Self.thorchainAsset(holding.reference,catalog:catalog,db:db) else { continue }
                try BalanceRecord(accountID:ticket.account.id,assetID:asset.id,networkID:"thorchain",amountAtomic:holding.amount,observedAt:time,source:"THORNode bank").upsert(db)
            }
            try db.execute(sql:"UPDATE thorchainSync SET observedAt=?,inventory=?,height=? WHERE accountID=?",arguments:[time,try JSONEncoder().encode(inventory),inventory.height,ticket.account.id])
        }
    }
    public func commitThorchainCatalog(_ catalog:ThorchainCatalog, ticket:ThorchainSyncTicket) async throws {
        try Self.validateThorchainCatalog(catalog)
        let entry = MarketCacheEntry(key: "thorchain.catalog", source: "THORChain",
            payload: try JSONEncoder().encode(catalog), fetchedAt: catalog.observedAt.timeIntervalSince1970)
        guard entry.payload.count <= 2_000_000 else { throw StoreError.invalidValue("THORChain catalog") }
        try await thorchainWrite { db in
            try Self.validateThorchain(ticket,db:db)
            let saved = try Self.newerThorchainCatalog(than: catalog, db: db)
            let catalog = saved ?? catalog
            // Register chain metadata before history can resume with an older
            // cache. Unowned tokens get no balance row and stay out of portfolios.
            for ref in catalog.tokens.keys { _ = try Self.thorchainAsset(ref,catalog:catalog,db:db) }
            if let data=try Data.fetchOne(db,sql:"SELECT inventory FROM thorchainSync WHERE accountID=?",arguments:[ticket.account.id]) {
                let inventory=try JSONDecoder().decode(ThorchainInventory.self,from:data)
                for holding in inventory.holdings {
                    guard let asset=try Self.thorchainAsset(holding.reference,catalog:catalog,db:db) else { continue }
                    try BalanceRecord(accountID:ticket.account.id,assetID:asset.id,networkID:"thorchain",amountAtomic:holding.amount,observedAt:inventory.observedAt.timeIntervalSince1970,source:"THORNode bank").upsert(db)
                }
            }
            for row in try Row.fetchAll(db,sql:"SELECT p.eventID,p.payload FROM thorchainPendingEvents p JOIN assets a ON a.networkID='thorchain' AND a.reference=p.reference WHERE p.accountID=? LIMIT 1000",arguments:[ticket.account.id]) {
                let event=try JSONDecoder().decode(ThorchainEvent.self,from:row["payload"])
                if try Self.projectThorchainEvent(event,ticket:ticket,catalog:catalog,db:db) {
                    try db.execute(sql:"DELETE FROM thorchainPendingEvents WHERE accountID=? AND eventID=?",arguments:[ticket.account.id,event.id])
                }
            }
            let assets=try AssetRecord.fetchAll(db,sql:"SELECT * FROM assets WHERE networkID='thorchain'")
            for old in assets {
                guard let asset=try Self.thorchainAsset(old.reference,catalog:catalog,db:db) else { continue }
                if let price=catalog.prices[asset.reference] {
                    try Validation.price(price)
                    try PriceRecord(assetID:asset.id,currency:"USD",value:price,observedAt:catalog.observedAt.timeIntervalSince1970,source:"THORChain markets").upsert(db)
                }
            }
            // Publish the ordering watermark with its metadata/projections.
            // No await or second transaction may expose only half the update.
            if saved == nil { try entry.upsert(db) }
        }
    }
    public func thorchainCursor(ticket:ThorchainSyncTicket, stream:String, lane:String, height:Int64) async throws -> ThorchainCursor {
        guard ["transfer.sender","transfer.recipient","message.sender"].contains(stream), ["recent","backfill"].contains(lane), height>0 else { throw StoreError.invalidValue("history cursor") }
        return try await thorchainWrite { db in
            try Self.validateThorchain(ticket,db:db)
            var cursor=try ThorchainCursor.fetchOne(db,key:["accountID":ticket.account.id,"stream":stream,"lane":lane]) ?? .init(accountID:ticket.account.id,stream:stream,lane:lane,height:height,lowerHeight:lane == "recent" ? max(0,height-100):0,page:1,complete:false)
            if lane == "recent", cursor.complete, height>cursor.height {
                cursor.lowerHeight=max(0,cursor.height-100); cursor.height=height; cursor.page=1; cursor.complete=false
            }
            try cursor.upsert(db); return cursor
        }
    }
    public func commitThorchainHistory(_ page:ThorchainHistoryPage, cursor:ThorchainCursor, ticket:ThorchainSyncTicket, catalog:ThorchainCatalog) async throws {
        guard page.owner == ticket.account.address, cursor.accountID == ticket.account.id else { throw StoreError.conflictingIdentity }
        try await thorchainWrite { db in
            try Self.validateThorchain(ticket,db:db)
            guard try ThorchainCursor.fetchOne(db,key:["accountID":cursor.accountID,"stream":cursor.stream,"lane":cursor.lane]) == cursor else { throw ThorchainSyncRejection.historyCursorChanged }
            guard !cursor.complete else { throw ThorchainSyncRejection.historyComplete }
            let catalog = try Self.newerThorchainCatalog(than: catalog, db: db) ?? catalog
            for event in page.events {
                try Validation.amount(event.amount)
                guard event.timestamp.isFinite, (cursor.lowerHeight...cursor.height).contains(event.height), ["confirmed","failed"].contains(event.state) else { throw StoreError.invalidValue("history") }
                if try !Self.projectThorchainEvent(event,ticket:ticket,catalog:catalog,db:db) {
                    try db.execute(sql:"INSERT INTO thorchainPendingEvents(accountID,eventID,reference,payload) VALUES(?,?,?,?) ON CONFLICT(accountID,eventID) DO UPDATE SET payload=excluded.payload",arguments:[ticket.account.id,event.id,event.reference,try JSONEncoder().encode(event)])
                }
            }
            var next=cursor
            if let value=page.next, let number=Int(value), number == cursor.page+1 { next.page=number }
            else if page.next == nil { next.complete=true }
            else { throw StoreError.invalidValue("history next page") }
            try next.update(db)
        }
    }
    private static func projectThorchainEvent(_ event:ThorchainEvent,ticket:ThorchainSyncTicket,catalog:ThorchainCatalog,db:Database) throws -> Bool {
        guard let asset=try thorchainAsset(event.reference,catalog:catalog,db:db) else { return false }
        let txID="thorchain:"+event.hash
        try TransactionRecord(id:txID,networkID:"thorchain",hash:event.hash,state:event.state,blockHeight:event.height,timestamp:event.timestamp,feeAtomic:event.fee,updatedAt:Date().timeIntervalSince1970).upsert(db)
        var activityID=ticket.account.id+":"+event.id
        if let send=try SendRecord.fetchOne(db,sql:"SELECT * FROM sends WHERE accountID=? AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[ticket.account.id,txID]) {
            // Failed history has no payment event. Preserve the reviewed intent
            // while the transaction state explains that no transfer occurred.
            if event.state=="failed" {return true}
            if event.direction=="outgoing",send.assetID==asset.id,send.recipient==event.counterparty,send.amountAtomic==event.amount {
                activityID=ticket.account.id+":"+event.hash+":"+event.reference
            }
        }
        try ActivityRecord(id:activityID,walletID:ticket.account.walletID,accountID:ticket.account.id,networkID:"thorchain",transactionID:txID,assetID:asset.id,direction:event.direction,amountAtomic:event.amount,counterparty:event.counterparty,timestamp:event.timestamp).upsert(db)
        return true
    }
}
