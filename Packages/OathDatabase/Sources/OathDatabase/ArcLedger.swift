import Foundation
import CryptoKit
import GRDB
import OathAnkr

public struct ArcSyncTicket: Sendable {
    public let account: AccountRecord
    public let runID: String
}
public struct ArcHistoryCursor: Codable, FetchableRecord, Sendable {
    public let accountID: String
    public let lane: String
    public let startBlock: Int64
    public let endBlock: Int64
    public let nextBlock: Int64
    public let complete: Bool
    public let failure: String?
}
extension OathDatabase {
    public func beginArcSync(accountID: String, now: Date = .now) async throws -> ArcSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "arc" else { throw StoreError.missingRecord }
            let id = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO arcSync(accountID,runID) VALUES(?,?)
                ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL
                """, arguments: [accountID,id])
            return .init(account: account, runID: id)
        }
    }
    private static func validateArc(_ ticket: ArcSyncTicket, db: Database) throws {
        guard let account = try AccountRecord.fetchOne(db, key: ticket.account.id), account.networkID == "arc",
              account.address == ticket.account.address, account.syncGeneration == ticket.account.syncGeneration,
              try String.fetchOne(db, sql: "SELECT runID FROM arcSync WHERE accountID=?", arguments: [account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func knownArcTokens(accountID: String) async throws -> [ArcToken] {
        try await pool.read { db in
            let records = try AssetRecord.fetchAll(db, sql: """
                SELECT a.* FROM assets a WHERE a.networkID='arc' AND a.reference<>'native' AND
                (EXISTS(SELECT 1 FROM arcHoldings h WHERE h.accountID=? AND h.assetID=a.id)
                OR EXISTS(SELECT 1 FROM trackedAssets t WHERE t.accountID=? AND t.assetID=a.id)
                OR EXISTS(SELECT 1 FROM activity e WHERE e.accountID=? AND e.assetID=a.id))
                """, arguments: [accountID,accountID,accountID])
            return try records.map { try ArcToken(reference: $0.reference, name: $0.name, symbol: $0.symbol, decimals: $0.decimals, logo: $0.logo) }
        }
    }
    public func commitArcInventory(_ value: ArcInventory, ticket: ArcSyncTicket, catalog: ArcCatalog) async throws {
        guard value.owner.lowercased() == ticket.account.address.lowercased(), value.block >= 0,
              value.holdings.contains(where: { $0.token.reference == "native" && $0.amount != nil }),
              Set(value.holdings.map { $0.token.reference }).count == value.holdings.count else { throw StoreError.conflictingIdentity }
        try await pool.write { db in
            try Self.validateArc(ticket, db: db)
            let previous = try Int64.fetchOne(db, sql: "SELECT checkpoint FROM arcSync WHERE accountID=?", arguments: [ticket.account.id])
            guard previous.map({ $0 <= value.block }) ?? true else { throw StoreError.staleSync }
            let now = value.observedAt.timeIntervalSince1970
            for holding in value.holdings {
                // A single reverting contract cannot clear its last known balance.
                guard let amount = holding.amount else { continue }
                try Validation.amount(amount)
                let token = holding.token
                guard try ArcIdentity.reference(token.reference) == token.reference,
                      token.reference != "native" || token.decimals == 18 else { throw StoreError.conflictingIdentity }
                // A catalog is not an owned-token list. Keep zeroes only for
                // already known or explicitly tracked assets.
                if token.reference != "native", amount == "0",
                   try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM arcHoldings WHERE accountID=? AND reference=?) OR EXISTS(SELECT 1 FROM trackedAssets t JOIN assets a ON a.id=t.assetID WHERE t.accountID=? AND a.networkID='arc' AND a.reference=?)",
                       arguments: [ticket.account.id,token.reference,ticket.account.id,token.reference])! { continue }
                let asset = try Self.ankrAsset(networkID: "arc", reference: token.reference,
                    name: token.name, symbol: token.symbol, decimals: token.decimals, logo: token.logo, db: db)
                let oldVerified = (try Int.fetchOne(db, sql: "SELECT verified FROM arcHoldings WHERE accountID=? AND reference=?", arguments: [ticket.account.id,token.reference])) == 1
                let verified = catalog.contains(token.reference) || (catalog.ids.isEmpty && oldVerified)
                try db.execute(sql: """
                    INSERT INTO arcHoldings(accountID,reference,assetID,detail,amountAtomic,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET detail=excluded.detail,amountAtomic=excluded.amountAtomic,
                        observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=excluded.verified
                    """, arguments: [ticket.account.id,token.reference,asset.id,try JSONEncoder().encode(token),amount,now,value.block,verified])
            }
            // This flag describes state reads only. Archive discovery coverage
            // lives in arcHistoryCursors and is never inferred from this batch.
            try db.execute(sql: "UPDATE arcSync SET inventory=?,observedAt=?,checkpoint=?,complete=?,failure=? WHERE accountID=?", arguments: [value.raw,now,value.block,value.complete,value.complete ? nil : "incompleteInventory",ticket.account.id])
        }
    }
    public func prepareArcHistory(_ ticket: ArcSyncTicket, through end: Int64) async throws {
        guard end > 0, end < Int64.max else { throw StoreError.invalidValue("Arc history range") }
        try await pool.write { db in
            try Self.validateArc(ticket, db: db)
            let old = try ArcHistoryCursor.fetchOne(db, sql: "SELECT * FROM arcHistoryCursors WHERE accountID=? AND lane='recent'", arguments: [ticket.account.id])
            // Keep interrupted intervals exactly; a subsequent refresh catches
            // the next interval. Backfill can never create a hole on refresh.
            let recent = max(0,end - 200_000)
            if old == nil || old!.complete {
                let start = old.map { max(0,$0.endBlock - 100) } ?? recent
                guard start < end else { return }
                try db.execute(sql: """
                    INSERT INTO arcHistoryCursors(accountID,lane,startBlock,endBlock,nextBlock) VALUES(?,'recent',?,?,?)
                    ON CONFLICT(accountID,lane) DO UPDATE SET startBlock=excluded.startBlock,endBlock=excluded.endBlock,
                        nextBlock=excluded.nextBlock,complete=0,failure=NULL
                    """, arguments: [ticket.account.id,start,end,start])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO arcHistoryCursors(accountID,lane,startBlock,endBlock,nextBlock,complete) VALUES(?,'backfill',0,?,0,?)", arguments: [ticket.account.id,recent,recent == 0])
        }
    }
    public func arcHistoryWork(_ ticket: ArcSyncTicket) async throws -> [ArcHistoryCursor] {
        try await pool.read { db in
            try Self.validateArc(ticket, db: db)
            return try ArcHistoryCursor.fetchAll(db, sql: "SELECT * FROM arcHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC", arguments: [ticket.account.id])
        }
    }
    public func commitArcPage(_ page: ArcHistoryPage, cursor: ArcHistoryCursor, ticket: ArcSyncTicket) async throws {
        guard page.fromBlock == cursor.nextBlock, page.nextBlock > cursor.nextBlock, page.nextBlock <= cursor.endBlock else { throw StoreError.conflictingIdentity }
        try await pool.write { db in
            try Self.validateArc(ticket, db: db)
            guard let current = try ArcHistoryCursor.fetchOne(db, sql: "SELECT * FROM arcHistoryCursors WHERE accountID=? AND lane=?", arguments: [ticket.account.id,cursor.lane]),
                  current.nextBlock == cursor.nextBlock, current.endBlock == cursor.endBlock,
                  current.startBlock == cursor.startBlock, !current.complete else { throw StoreError.staleSync }
            let now = Date().timeIntervalSince1970, owner = ticket.account.address.lowercased()
            let transactions = Dictionary(page.transactions.map { ($0.hash,$0) },uniquingKeysWith:{ first,_ in first })
            guard transactions.count == page.transactions.count, Set(page.events.map(\.id)).count == page.events.count else { throw StoreError.conflictingIdentity }
            // Signed local intents already own an activity row. Preserve it when
            // archive logs arrive; do not show a duplicate outgoing transfer.
            let localSends=try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE accountID=? AND networkID='arc' AND signedPayload IS NOT NULL",arguments:[ticket.account.id])
            let localTransactions=Set(localSends.compactMap(\.transactionID))
            for tx in page.transactions {
                guard AnkrQuantity.hash(tx.hash), tx.block >= page.fromBlock, tx.block < page.nextBlock,
                      tx.timestamp.isFinite, tx.timestamp >= 0, AnkrQuantity.address(tx.from),
                      tx.to.map(AnkrQuantity.address) ?? true,
                      tx.from == owner || tx.to == owner || page.events.contains(where: { $0.hash == tx.hash && ($0.from == owner || $0.to == owner) }) else { throw StoreError.conflictingIdentity }
                try Validation.amount(tx.fee)
                var record = TransactionRecord(id:"arc:" + tx.hash,networkID:"arc",hash:tx.hash,state:tx.failed ? "failed" : "confirmed",timestamp:tx.timestamp,updatedAt:now)
                record.blockHeight = tx.block; record.feeAtomic = tx.fee; try record.upsert(db)
            }
            for event in page.events {
                guard let tx = transactions[event.hash], !tx.failed, event.from == owner || event.to == owner,
                      AnkrQuantity.address(event.from), AnkrQuantity.address(event.to), event.logIndex >= 0,
                      event.id == event.hash + ":" + String(event.logIndex),
                      try ArcIdentity.reference(event.token.reference) == event.token.reference,
                      event.token.reference != "native" || event.token.decimals == 18 else { throw StoreError.conflictingIdentity }
                try Validation.amount(event.amount)
                let token = event.token, txID = "arc:" + event.hash, eventID = "arc:" + event.id
                let asset = try Self.ankrAsset(networkID:"arc",reference:token.reference,name:token.name,symbol:token.symbol,decimals:token.decimals,logo:token.logo,db:db)
                try TransferRecord(id:eventID,transactionID:txID,networkID:"arc",assetID:asset.id,eventIndex:event.logIndex,
                    fromAddress:event.from,toAddress:event.to,amountAtomic:event.amount).upsert(db)
                let direction = event.from == owner ? (event.to == owner ? "self" : "outgoing") : "incoming"
                if !localTransactions.contains(txID) {
                try ActivityRecord(id:ticket.account.id + ":" + eventID,walletID:ticket.account.walletID,accountID:ticket.account.id,
                    networkID:"arc",transactionID:txID,assetID:asset.id,direction:direction,amountAtomic:event.amount,
                    counterparty:direction == "incoming" ? event.from : event.to,timestamp:tx.timestamp).upsert(db)
                }
                try db.execute(sql:"INSERT INTO arcEvents(accountID,id,hash,detail) VALUES(?,?,?,?) ON CONFLICT(accountID,id) DO UPDATE SET detail=excluded.detail",
                    arguments:[ticket.account.id,event.id,event.hash,try JSONEncoder().encode(event)])
            }
            // Failed and zero-value calls still belong in activity. Successful
            // native sends are represented only by their EIP-7708 log above.
            let native = try Self.ankrAsset(networkID:"arc",reference:"native",name:"USDC",symbol:"USDC",decimals:18,logo:nil,db:db)
            for tx in page.transactions where !page.events.contains(where: { $0.hash == tx.hash }) && !localTransactions.contains("arc:"+tx.hash) {
                let direction = tx.from == owner ? (tx.to == owner ? "self" : "outgoing") : "incoming"
                try ActivityRecord(id:ticket.account.id + ":arc:" + tx.hash + ":call",walletID:ticket.account.walletID,accountID:ticket.account.id,
                    networkID:"arc",transactionID:"arc:" + tx.hash,assetID:native.id,direction:direction,amountAtomic:"0",
                    counterparty:direction == "incoming" ? tx.from : (tx.to ?? ""),timestamp:tx.timestamp).upsert(db)
            }
            try db.execute(sql:"INSERT INTO arcPages(accountID,startBlock,endBlock,raw) VALUES(?,?,?,?) ON CONFLICT(accountID,startBlock,endBlock) DO UPDATE SET raw=excluded.raw",arguments:[ticket.account.id,page.fromBlock,page.nextBlock,page.raw])
            try db.execute(sql:"UPDATE arcHistoryCursors SET nextBlock=?,complete=?,failure=NULL WHERE accountID=? AND lane=?",arguments:[page.nextBlock,page.nextBlock == cursor.endBlock,ticket.account.id,cursor.lane])
        }
    }
    public func failArcSync(_ ticket: ArcSyncTicket, lane: String? = nil, code: String) async throws {
        try await pool.write { db in
            try Self.validateArc(ticket, db: db)
            if let lane { try db.execute(sql:"UPDATE arcHistoryCursors SET failure=? WHERE accountID=? AND lane=?",arguments:[code,ticket.account.id,lane]) }
            else { try db.execute(sql:"UPDATE arcSync SET failure=? WHERE accountID=?",arguments:[code,ticket.account.id]) }
        }
    }
}
