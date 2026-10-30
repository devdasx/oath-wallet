import Foundation
import CryptoKit
import GRDB
import OathAnkr

public struct HyperEVMSyncTicket: Sendable {
    public let account: AccountRecord
    public let runID: String
}
public struct HyperEVMHistoryCursor: Codable, FetchableRecord, Sendable {
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
    public func beginHyperEVMSync(accountID: String, now: Date = .now) async throws -> HyperEVMSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "hyperevm" else { throw StoreError.missingRecord }
            let id = UUID().uuidString, end = now.timeIntervalSince1970, recent = max(0, end - 86_400)
            try db.execute(sql: """
                INSERT INTO hyperevmSync(accountID,runID) VALUES(?,?)
                ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID,failure=NULL
                """, arguments: [accountID,id])
            for stream in HyperEVMHistoryStream.allCases {
                let old = try HyperEVMHistoryCursor.fetchOne(db, sql: "SELECT * FROM hyperevmHistoryCursors WHERE accountID=? AND stream=? AND lane='recent'", arguments: [accountID,stream.rawValue])
                // Never abandon an interrupted recent interval. The backfill
                // lane retains its cursor independently across refreshes.
                if old == nil || old!.complete {
                    let start = old.map { max(0, $0.endTime - 86_400) } ?? recent
                    try db.execute(sql: """
                        INSERT INTO hyperevmHistoryCursors(accountID,stream,lane,startTime,endTime) VALUES(?,?,'recent',?,?)
                        ON CONFLICT(accountID,stream,lane) DO UPDATE SET startTime=excluded.startTime,endTime=excluded.endTime,cursor=NULL,complete=0,failure=NULL
                        """, arguments: [accountID,stream.rawValue,start,end])
                }
                try db.execute(sql: "INSERT OR IGNORE INTO hyperevmHistoryCursors(accountID,stream,lane,startTime,endTime) VALUES(?,?,'backfill',0,?)", arguments: [accountID,stream.rawValue,recent])
            }
            return .init(account: account, runID: id)
        }
    }
    private static func validateHyperEVM(_ ticket: HyperEVMSyncTicket, db: Database) throws {
        guard let account = try AccountRecord.fetchOne(db, key: ticket.account.id), account.networkID == "hyperevm",
              account.address == ticket.account.address, account.syncGeneration == ticket.account.syncGeneration,
              try String.fetchOne(db, sql: "SELECT runID FROM hyperevmSync WHERE accountID=?", arguments: [account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    public func knownHyperEVMTokens(accountID: String) async throws -> [HyperEVMToken] {
        try await pool.read { db in
            let records = try AssetRecord.fetchAll(db, sql: """
                SELECT a.* FROM assets a WHERE a.networkID='hyperevm' AND a.reference<>'native' AND
                (EXISTS(SELECT 1 FROM hyperevmHoldings h WHERE h.accountID=? AND h.assetID=a.id)
                OR EXISTS(SELECT 1 FROM trackedAssets t WHERE t.accountID=? AND t.assetID=a.id))
                """, arguments: [accountID,accountID])
            return try records.map { try HyperEVMToken(reference: $0.reference, name: $0.name, symbol: $0.symbol, decimals: $0.decimals, logo: $0.logo) }
        }
    }
    public func commitHyperEVMInventory(_ value: HyperEVMInventory, ticket: HyperEVMSyncTicket, catalog: HyperEVMCatalog) async throws {
        guard value.owner.lowercased() == ticket.account.address.lowercased(), value.block >= 0,
              value.holdings.contains(where: { $0.token.reference == "native" && $0.amount != nil }),
              Set(value.holdings.map { $0.token.reference }).count == value.holdings.count else { throw StoreError.conflictingIdentity }
        try await pool.write { db in
            try Self.validateHyperEVM(ticket, db: db)
            let previous = try Int64.fetchOne(db, sql: "SELECT checkpoint FROM hyperevmSync WHERE accountID=?", arguments: [ticket.account.id])
            guard previous.map({ $0 <= value.block }) ?? true else { throw StoreError.staleSync }
            let now = value.observedAt.timeIntervalSince1970
            for holding in value.holdings {
                // A single reverting contract cannot clear its last known balance.
                guard let amount = holding.amount else { continue }
                try Validation.amount(amount)
                let token = holding.token
                let asset = try Self.ankrAsset(networkID: "hyperevm", reference: token.reference,
                    name: token.name, symbol: token.symbol, decimals: token.decimals, logo: token.logo, db: db)
                let oldVerified = (try Int.fetchOne(db, sql: "SELECT verified FROM hyperevmHoldings WHERE accountID=? AND reference=?", arguments: [ticket.account.id,token.reference])) == 1
                let verified = catalog.contains(token.reference) || (catalog.ids.isEmpty && oldVerified)
                try db.execute(sql: """
                    INSERT INTO hyperevmHoldings(accountID,reference,assetID,detail,amountAtomic,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?,?)
                    ON CONFLICT(accountID,reference) DO UPDATE SET detail=excluded.detail,amountAtomic=excluded.amountAtomic,
                        observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=excluded.verified
                    WHERE excluded.checkpoint>hyperevmHoldings.checkpoint OR (excluded.checkpoint=hyperevmHoldings.checkpoint AND excluded.observedAt>=hyperevmHoldings.observedAt)
                    """, arguments: [ticket.account.id,token.reference,asset.id,try JSONEncoder().encode(token),amount,now,value.block,verified])
            }
            // Missing index access is not a successful empty inventory. Keep
            // cached holdings and record partial coverage separately from units.
            try db.execute(sql: "UPDATE hyperevmSync SET inventory=?,observedAt=?,checkpoint=?,complete=?,failure=? WHERE accountID=?", arguments: [value.raw,now,value.block,value.complete,value.complete ? nil : "incompleteInventory",ticket.account.id])
        }
    }
    public func hyperevmHistoryWork(_ ticket: HyperEVMSyncTicket) async throws -> [HyperEVMHistoryCursor] {
        try await pool.read { db in
            try Self.validateHyperEVM(ticket, db: db)
            return try HyperEVMHistoryCursor.fetchAll(db, sql: "SELECT * FROM hyperevmHistoryCursors WHERE accountID=? AND complete=0 ORDER BY lane DESC,stream", arguments: [ticket.account.id])
        }
    }
    public func commitHyperEVMPage(_ page: HyperEVMHistoryPage, cursor: HyperEVMHistoryCursor, ticket: HyperEVMSyncTicket) async throws {
        guard page.next == nil || page.next != cursor.cursor else { throw AnkrError.paginationLoop }
        try await pool.write { db in
            try Self.validateHyperEVM(ticket, db: db)
            guard let current = try HyperEVMHistoryCursor.fetchOne(db, sql: "SELECT * FROM hyperevmHistoryCursors WHERE accountID=? AND stream=? AND lane=?", arguments: [ticket.account.id,cursor.stream,cursor.lane]),
                  current.cursor == cursor.cursor, current.startTime == cursor.startTime, current.endTime == cursor.endTime,
                  !current.complete else { throw StoreError.staleSync }
            let now = Date().timeIntervalSince1970, owner = ticket.account.address.lowercased()
            for event in page.events {
                guard event.from == owner || event.to == owner, event.timestamp >= cursor.startTime, event.timestamp <= cursor.endTime,
                      event.block >= 0, AnkrQuantity.hash(event.hash) else { throw StoreError.conflictingIdentity }
                try Validation.amount(event.amount)
                // Keep every verified log, even a nonstandard contract with no
                // decimals. Such events never enter formatted asset activity.
                try db.execute(sql: "INSERT INTO hyperevmEvents(accountID,id,hash,detail) VALUES(?,?,?,?) ON CONFLICT(accountID,id) DO UPDATE SET detail=excluded.detail", arguments: [ticket.account.id,event.id,event.hash,try JSONEncoder().encode(event)])
                guard let token = event.token else { continue }
                let txID = "hyperevm:" + event.hash
                let asset = try Self.ankrAsset(networkID: "hyperevm", reference: token.reference, name: token.name,
                    symbol: token.symbol, decimals: token.decimals, logo: token.logo, db: db)
                var tx = try TransactionRecord.fetchOne(db, key: txID) ?? TransactionRecord(id: txID, networkID: "hyperevm", hash: event.hash, state: "confirmed", timestamp: event.timestamp, updatedAt: now)
                // Failure of a nested call does not mean the parent failed.
                if cursor.stream == HyperEVMHistoryStream.transactions.rawValue { tx.state = event.failed ? "failed" : "confirmed" }
                // A new inclusion height invalidates the previous receipt reference.
                if tx.blockHeight != event.block { tx.blockHash = nil }
                tx.blockHeight = event.block; tx.timestamp = event.timestamp; tx.updatedAt = now
                if let fee = event.fee { try Validation.amount(fee); tx.feeAtomic = fee }
                try tx.upsert(db)
                let eventID = "hyperevm:" + event.id
                let direction = event.from == owner ? (event.to == owner ? "self" : "outgoing") : "incoming"
                try TransferRecord(id: eventID, transactionID: txID, networkID: "hyperevm", assetID: asset.id,
                    eventIndex: Int(event.id.split(separator: ":").last ?? "") ?? -1,
                    fromAddress: event.from, toAddress: event.to, amountAtomic: event.amount).upsert(db)
                try ActivityRecord(id: ticket.account.id + ":" + eventID, walletID: ticket.account.walletID, accountID: ticket.account.id,
                    networkID: "hyperevm", transactionID: txID, assetID: asset.id, direction: direction, amountAtomic: event.amount,
                    counterparty: direction == "incoming" ? event.from : event.to, timestamp: event.timestamp).upsert(db)

            }
            let key = cursor.stream + ":" + cursor.lane + ":" + String(cursor.startTime) + ":" + String(cursor.endTime) + ":" + SHA256.hash(data: Data((cursor.cursor ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: "INSERT INTO hyperevmPages(accountID,pageKey,raw) VALUES(?,?,?) ON CONFLICT(accountID,pageKey) DO UPDATE SET raw=excluded.raw", arguments: [ticket.account.id,key,page.raw])
            try db.execute(sql: "UPDATE hyperevmHistoryCursors SET cursor=?,complete=?,failure=NULL WHERE accountID=? AND stream=? AND lane=?", arguments: [page.next,page.next == nil,ticket.account.id,cursor.stream,cursor.lane])
        }
    }
    /// An expired index cursor can replay its fixed time window safely because
    /// events are upserted by transaction/log identity. Never discard history.
    public func restartHyperEVMHistory(_ cursor: HyperEVMHistoryCursor, ticket: HyperEVMSyncTicket) async throws {
        try await pool.write { db in
            try Self.validateHyperEVM(ticket, db: db)
            guard cursor.cursor != nil, let current = try HyperEVMHistoryCursor.fetchOne(db,
                sql: "SELECT * FROM hyperevmHistoryCursors WHERE accountID=? AND stream=? AND lane=?",
                arguments: [ticket.account.id,cursor.stream,cursor.lane]),
                !current.complete, current.cursor == cursor.cursor, current.startTime == cursor.startTime,
                current.endTime == cursor.endTime else { throw StoreError.staleSync }
            try db.execute(sql: "UPDATE hyperevmHistoryCursors SET cursor=NULL,failure=NULL WHERE accountID=? AND stream=? AND lane=?",
                arguments: [ticket.account.id,cursor.stream,cursor.lane])
        }
    }
    public func failHyperEVMSync(_ ticket: HyperEVMSyncTicket, cursor: HyperEVMHistoryCursor? = nil, code: String) async throws {
        try await pool.write { db in
            try Self.validateHyperEVM(ticket, db: db)
            if let cursor {
                try db.execute(sql: "UPDATE hyperevmHistoryCursors SET failure=? WHERE accountID=? AND stream=? AND lane=?", arguments: [code,ticket.account.id,cursor.stream,cursor.lane])
            } else { try db.execute(sql: "UPDATE hyperevmSync SET failure=? WHERE accountID=?", arguments: [code,ticket.account.id]) }
        }
    }
}
