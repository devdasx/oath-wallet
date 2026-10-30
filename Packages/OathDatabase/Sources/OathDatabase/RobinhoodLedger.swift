import Foundation
import CryptoKit
import GRDB
import OathAnkr

public struct RobinhoodSyncTicket: Sendable {
    public let account: AccountRecord
    public let runID: String
}
public struct RobinhoodHistoryCursor: Codable, FetchableRecord, Sendable {
    public let accountID: String
    public let stream: String
    public let lane: String
    public let startTime: Double
    public let endTime: Double
    public let cursor: String?
    public let complete: Bool
    public let failure: String?
}
extension OathDatabase {
    public func beginRobinhoodSync(accountID: String, now: Date = .now) async throws -> RobinhoodSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "robinhood" else { throw StoreError.missingRecord }
            let id = UUID().uuidString, end = now.timeIntervalSince1970, recent = max(0, end - 86_400)
            try db.execute(sql: """
                INSERT INTO robinhoodSync(accountID,runID) VALUES(?,?)
                ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL
                """, arguments: [accountID,id])
            for stream in RobinhoodHistoryStream.allCases {
                let old = try RobinhoodHistoryCursor.fetchOne(db, sql: "SELECT * FROM robinhoodHistoryCursors WHERE accountID=? AND stream=? AND lane='recent'", arguments: [accountID,stream.rawValue])
                // Never abandon an interrupted recent interval. The backfill
                // lane retains its cursor independently across refreshes.
                if old == nil || old!.complete {
                    let start = old.map { max(0, $0.endTime - 86_400) } ?? recent
                    try db.execute(sql: """
                        INSERT INTO robinhoodHistoryCursors(accountID,stream,lane,startTime,endTime) VALUES(?,?,'recent',?,?)
                        ON CONFLICT(accountID,stream,lane) DO UPDATE SET startTime=excluded.startTime,endTime=excluded.endTime,cursor=NULL,complete=0,failure=NULL
                        """, arguments: [accountID,stream.rawValue,start,end])
                }
                try db.execute(sql: "INSERT OR IGNORE INTO robinhoodHistoryCursors(accountID,stream,lane,startTime,endTime) VALUES(?,?,'backfill',0,?)", arguments: [accountID,stream.rawValue,recent])
            }
            return .init(account: account, runID: id)
        }
    }
    private static func validateRobinhood(_ ticket: RobinhoodSyncTicket, db: Database) throws {
        guard let account = try AccountRecord.fetchOne(db, key: ticket.account.id), account.networkID == "robinhood",
              account.address == ticket.account.address, account.syncGeneration == ticket.account.syncGeneration,
              try String.fetchOne(db, sql: "SELECT runID FROM robinhoodSync WHERE accountID=?", arguments: [account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func knownRobinhoodTokens(accountID: String) async throws -> [RobinhoodToken] {
        try await pool.read { db in
            let records = try AssetRecord.fetchAll(db, sql: """
                SELECT a.* FROM assets a WHERE a.networkID='robinhood' AND a.reference<>'native' AND
                (EXISTS(SELECT 1 FROM robinhoodHoldings h WHERE h.accountID=? AND h.assetID=a.id)
                OR EXISTS(SELECT 1 FROM trackedAssets t WHERE t.accountID=? AND t.assetID=a.id))
                """, arguments: [accountID,accountID])
            return try records.map { try RobinhoodToken(reference: $0.reference, name: $0.name, symbol: $0.symbol, decimals: $0.decimals, logo: $0.logo) }
        }
    }
    public func commitRobinhoodInventory(_ value: RobinhoodInventory, ticket: RobinhoodSyncTicket, catalog: RobinhoodCatalog) async throws {
        guard value.owner.lowercased() == ticket.account.address.lowercased(), value.block >= 0,
              value.holdings.contains(where: { $0.token.reference == "native" && $0.amount != nil }),
              Set(value.holdings.map { $0.token.reference }).count == value.holdings.count else { throw StoreError.conflictingIdentity }
        try await pool.write { db in
            try Self.validateRobinhood(ticket, db: db)
            let previous = try Int64.fetchOne(db, sql: "SELECT checkpoint FROM robinhoodSync WHERE accountID=?", arguments: [ticket.account.id])
            guard previous.map({ $0 <= value.block }) ?? true else { throw StoreError.staleSync }
            let now = value.observedAt.timeIntervalSince1970
            for holding in value.holdings {
                // A single reverting contract cannot clear its last known balance.
                guard let amount = holding.amount else { continue }
                try Validation.amount(amount)
                let token = holding.token
                let asset = try Self.ankrAsset(networkID: "robinhood", reference: token.reference,
                    name: token.name, symbol: token.symbol, decimals: token.decimals, logo: token.logo, db: db)
                let oldVerified = (try Int.fetchOne(db, sql: "SELECT verified FROM robinhoodHoldings WHERE accountID=? AND reference=?", arguments: [ticket.account.id,token.reference])) == 1
                let verified = catalog.contains(token.reference) || (catalog.ids.isEmpty && oldVerified)
                try db.execute(sql: """
                    INSERT INTO robinhoodHoldings(accountID,reference,assetID,detail,amountAtomic,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET detail=excluded.detail,amountAtomic=excluded.amountAtomic,
                        observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=excluded.verified
                    WHERE excluded.checkpoint>robinhoodHoldings.checkpoint OR (excluded.checkpoint=robinhoodHoldings.checkpoint AND excluded.observedAt>=robinhoodHoldings.observedAt)
                    """, arguments: [ticket.account.id,token.reference,asset.id,try JSONEncoder().encode(token),amount,now,value.block,verified])
            }
            // Missing index access is not a successful empty inventory. Keep
            // cached holdings and record partial coverage separately from units.
            try db.execute(sql: "UPDATE robinhoodSync SET inventory=?,observedAt=?,checkpoint=?,complete=?,failure=? WHERE accountID=?", arguments: [value.raw,now,value.block,value.complete,value.complete ? nil : "incompleteInventory",ticket.account.id])
        }
    }
    public func robinhoodHistoryWork(_ ticket: RobinhoodSyncTicket) async throws -> [RobinhoodHistoryCursor] {
        try await pool.read { db in
            try Self.validateRobinhood(ticket, db: db)
            return try RobinhoodHistoryCursor.fetchAll(db, sql: "SELECT * FROM robinhoodHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC,stream", arguments: [ticket.account.id])
        }
    }
    public func commitRobinhoodPage(_ page: RobinhoodHistoryPage, cursor: RobinhoodHistoryCursor, ticket: RobinhoodSyncTicket) async throws {
        guard page.next == nil || page.next != cursor.cursor else { throw AnkrError.paginationLoop }
        try await pool.write { db in
            try Self.validateRobinhood(ticket, db: db)
            guard let current = try RobinhoodHistoryCursor.fetchOne(db, sql: "SELECT * FROM robinhoodHistoryCursors WHERE accountID=? AND stream=? AND lane=?", arguments: [ticket.account.id,cursor.stream,cursor.lane]),
                  current.cursor == cursor.cursor, current.startTime == cursor.startTime, current.endTime == cursor.endTime,
                  !current.complete else { throw StoreError.staleSync }
            let now = Date().timeIntervalSince1970, owner = ticket.account.address.lowercased()
            for event in page.events {
                guard event.from == owner || event.to == owner, event.timestamp >= cursor.startTime, event.timestamp <= cursor.endTime,
                      event.block >= 0, AnkrQuantity.hash(event.hash) else { throw StoreError.conflictingIdentity }
                try Validation.amount(event.amount)
                let token = event.token, txID = "robinhood:" + event.hash
                let asset = try Self.ankrAsset(networkID: "robinhood", reference: token.reference, name: token.name,
                    symbol: token.symbol, decimals: token.decimals, logo: token.logo, db: db)
                var tx = try TransactionRecord.fetchOne(db, key: txID) ?? TransactionRecord(id: txID, networkID: "robinhood", hash: event.hash, state: "confirmed", timestamp: event.timestamp, updatedAt: now)
                // Failure of a nested call does not mean the parent failed.
                if cursor.stream == RobinhoodHistoryStream.transactions.rawValue { tx.state = event.failed ? "failed" : "confirmed" }
                // A new inclusion height invalidates the previous receipt reference.
                if tx.blockHeight != event.block { tx.blockHash = nil }
                tx.blockHeight = event.block; tx.timestamp = event.timestamp; tx.updatedAt = now
                if let fee = event.fee { try Validation.amount(fee); tx.feeAtomic = fee }
                try tx.upsert(db)
                let eventID = "robinhood:" + event.id
                let direction = event.from == owner ? (event.to == owner ? "self" : "outgoing") : "incoming"
                try TransferRecord(id: eventID, transactionID: txID, networkID: "robinhood", assetID: asset.id,
                    eventIndex: Int(event.id.split(separator: ":").last ?? "") ?? -1,
                    fromAddress: event.from, toAddress: event.to, amountAtomic: event.amount).upsert(db)
                try ActivityRecord(id: ticket.account.id + ":" + eventID, walletID: ticket.account.walletID, accountID: ticket.account.id,
                    networkID: "robinhood", transactionID: txID, assetID: asset.id, direction: direction, amountAtomic: event.amount,
                    counterparty: direction == "incoming" ? event.from : event.to, timestamp: event.timestamp).upsert(db)
                try db.execute(sql: "INSERT INTO robinhoodEvents(accountID,id,hash,detail) VALUES(?,?,?,?) ON CONFLICT(accountID,id) DO UPDATE SET detail=excluded.detail", arguments: [ticket.account.id,event.id,event.hash,try JSONEncoder().encode(event)])
            }
            let key = cursor.stream + ":" + cursor.lane + ":" + String(cursor.startTime) + ":" + String(cursor.endTime) + ":" + SHA256.hash(data: Data((cursor.cursor ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: "INSERT INTO robinhoodPages(accountID,pageKey,raw) VALUES(?,?,?) ON CONFLICT(accountID,pageKey) DO UPDATE SET raw=excluded.raw", arguments: [ticket.account.id,key,page.raw])
            try db.execute(sql: "UPDATE robinhoodHistoryCursors SET cursor=?,complete=?,failure=NULL WHERE accountID=? AND stream=? AND lane=?", arguments: [page.next,page.next == nil,ticket.account.id,cursor.stream,cursor.lane])
        }
    }
    /// An expired index cursor can replay its fixed time window safely because
    /// events are upserted by transaction/log identity. Never discard history.
    public func restartRobinhoodHistory(_ cursor: RobinhoodHistoryCursor, ticket: RobinhoodSyncTicket) async throws {
        try await pool.write { db in
            try Self.validateRobinhood(ticket, db: db)
            guard cursor.cursor != nil, let current = try RobinhoodHistoryCursor.fetchOne(db,
                sql: "SELECT * FROM robinhoodHistoryCursors WHERE accountID=? AND stream=? AND lane=?",
                arguments: [ticket.account.id,cursor.stream,cursor.lane]),
                !current.complete, current.cursor == cursor.cursor, current.startTime == cursor.startTime,
                current.endTime == cursor.endTime else { throw StoreError.staleSync }
            try db.execute(sql: "UPDATE robinhoodHistoryCursors SET cursor=NULL,failure=NULL WHERE accountID=? AND stream=? AND lane=?",
                arguments: [ticket.account.id,cursor.stream,cursor.lane])
        }
    }
    public func failRobinhoodSync(_ ticket: RobinhoodSyncTicket, cursor: RobinhoodHistoryCursor? = nil, code: String) async throws {
        try await pool.write { db in
            try Self.validateRobinhood(ticket, db: db)
            if let cursor {
                try db.execute(sql: "UPDATE robinhoodHistoryCursors SET failure=? WHERE accountID=? AND stream=? AND lane=?", arguments: [code,ticket.account.id,cursor.stream,cursor.lane])
            } else { try db.execute(sql: "UPDATE robinhoodSync SET failure=? WHERE accountID=?", arguments: [code,ticket.account.id]) }
        }
    }
}
