import Foundation
import GRDB
import OathAnkr

public struct PolkadotSyncTicket: Sendable { public let account: AccountRecord; public let runID: String }
public struct PolkadotHistoryCursor: Sendable { public let page: Int; public let upperHeight: Int64; public let lowerHeight: Int64 }
extension OathDatabase {
    public func beginPolkadotSync(accountID: String) async throws -> PolkadotSyncTicket {
        try await pool.write { db in
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.networkID == "polkadot",
                  let wallet = try WalletRecord.fetchOne(db, key: account.walletID), wallet.deletedAt == nil else { throw StoreError.missingRecord }
            _ = try PolkadotIdentity.address(account.address)
            let run = UUID().uuidString
            try db.execute(sql: "INSERT INTO polkadotSync(accountID,runID) VALUES(?,?) ON CONFLICT(accountID) DO UPDATE SET runID=excluded.runID", arguments: [accountID, run])
            return .init(account: account, runID: run)
        }
    }
    private static func validatePolkadot(_ ticket: PolkadotSyncTicket, db: Database) throws {
        guard try AccountRecord.fetchOne(db, key: ticket.account.id) == ticket.account,
              let wallet = try WalletRecord.fetchOne(db, key: ticket.account.walletID), wallet.deletedAt == nil,
              try String.fetchOne(db, sql: "SELECT runID FROM polkadotSync WHERE accountID=?", arguments: [ticket.account.id]) == ticket.runID else { throw StoreError.staleSync }
    }
    private static func polkadotAsset(_ token: PolkadotToken, db: Database) throws -> AssetRecord {
        guard !token.reference.isEmpty, token.reference.count <= 1100, (0...255).contains(token.decimals), token.name.utf8.count <= 4096, token.symbol.utf8.count <= 4096 else { throw StoreError.invalidValue("Polkadot metadata") }
        let asset = AssetRecord(id: "polkadot:" + token.reference, networkID: "polkadot", reference: token.reference, name: token.name, symbol: token.symbol, decimals: token.decimals, logo: token.reference == "native" ? "network-polkadot" : nil)
        if let old = try AssetRecord.fetchOne(db, key: asset.id), old.decimals != token.decimals { throw StoreError.conflictingIdentity }
        try asset.upsert(db)
        if token.coinGeckoID != nil, token.reference != "native" {
            try db.execute(sql: "INSERT INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt) VALUES('polkadot',?,'polkadot.registry',?,?) ON CONFLICT(networkID,reference,source) DO UPDATE SET decimals=excluded.decimals,observedAt=excluded.observedAt", arguments: [token.reference, token.decimals, Date().timeIntervalSince1970])
        }
        return asset
    }
    public func commitPolkadotInventory(_ value: PolkadotInventory, ticket: PolkadotSyncTicket) async throws {
        guard value.owner == (try PolkadotIdentity.address(ticket.account.address)), value.height > 0,
              value.observedAt.timeIntervalSince1970.isFinite, value.holdings.count <= 10_000,
              value.holdings.filter({ $0.token.reference == "native" }).count == 1,
              Set(value.holdings.map(\.token.reference)).count == value.holdings.count else { throw StoreError.conflictingIdentity }
        try await pool.write { db in
            try Self.validatePolkadot(ticket, db: db)
            let height = try Int64.fetchOne(db, sql: "SELECT height FROM polkadotSync WHERE accountID=?", arguments: [ticket.account.id]) ?? 0
            let time = try Double.fetchOne(db, sql: "SELECT observedAt FROM polkadotSync WHERE accountID=?", arguments: [ticket.account.id]) ?? 0
            guard value.height >= height, value.observedAt.timeIntervalSince1970 >= time else { throw StoreError.staleSync }
            try db.execute(sql: "UPDATE polkadotHoldings SET amountAtomic='0',observedAt=?,checkpoint=? WHERE accountID=?", arguments: [value.observedAt.timeIntervalSince1970, value.height, ticket.account.id])
            for holding in value.holdings {
                _ = try AtomicAmount(holding.amount)
                let asset = try Self.polkadotAsset(holding.token, db: db)
                try db.execute(sql: "INSERT INTO polkadotHoldings(accountID,reference,assetID,amountAtomic,observedAt,checkpoint,verified) VALUES(?,?,?,?,?,?,?) ON CONFLICT(accountID,reference) DO UPDATE SET assetID=excluded.assetID,amountAtomic=excluded.amountAtomic,observedAt=excluded.observedAt,checkpoint=excluded.checkpoint,verified=MAX(polkadotHoldings.verified,excluded.verified)", arguments: [ticket.account.id, holding.token.reference, asset.id, holding.amount, value.observedAt.timeIntervalSince1970, value.height, holding.token.coinGeckoID != nil])
            }
            try db.execute(sql: "UPDATE polkadotSync SET height=?,observedAt=?,inventory=? WHERE accountID=?", arguments: [value.height, value.observedAt.timeIntervalSince1970, try JSONEncoder().encode(value), ticket.account.id])
        }
    }
    public func polkadotInventory(accountID: String) async throws -> PolkadotInventory? {
        try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT inventory FROM polkadotSync WHERE accountID=?", arguments: [accountID]).map { try JSONDecoder().decode(PolkadotInventory.self, from: $0) }
        }
    }
    public func polkadotHistoryCursor(_ ticket: PolkadotSyncTicket, stream: String, latestHeight: Int64) async throws -> PolkadotHistoryCursor {
        try await pool.write { db in
            try Self.validatePolkadot(ticket, db: db)
            let row = try Row.fetchOne(db, sql: "SELECT * FROM polkadotHistory WHERE accountID=? AND stream=?", arguments: [ticket.account.id, stream])
            if let row {
                let page: Int = row["page"], upper: Int64 = row["upperHeight"], lower: Int64 = row["lowerHeight"]
                if page >= 0 || latestHeight <= upper { return .init(page: page, upperHeight: upper, lowerHeight: lower) }
                try db.execute(sql: "UPDATE polkadotHistory SET page=0,upperHeight=?,lowerHeight=? WHERE accountID=? AND stream=?", arguments: [latestHeight, upper, ticket.account.id, stream])
                return .init(page: 0, upperHeight: latestHeight, lowerHeight: upper)
            }
            try db.execute(sql: "INSERT INTO polkadotHistory(accountID,stream,page,upperHeight,lowerHeight) VALUES(?,?,0,?,0)", arguments: [ticket.account.id, stream, latestHeight])
            return .init(page: 0, upperHeight: latestHeight, lowerHeight: 0)
        }
    }
    public func commitPolkadotHistory(_ page: PolkadotHistoryPage, ticket: PolkadotSyncTicket, stream: String, currentPage: Int, advance: Bool) async throws {
        guard page.events.count <= 100, page.next == nil || page.next == currentPage + 1 else { throw StoreError.invalidValue("Polkadot page") }
        try await pool.write { db in
            try Self.validatePolkadot(ticket, db: db)
            if advance {
                let expected = try Int.fetchOne(db, sql: "SELECT page FROM polkadotHistory WHERE accountID=? AND stream=?", arguments: [ticket.account.id, stream]) ?? 0
                guard currentPage == expected else { throw StoreError.staleSync }
            }
            let owner = try PolkadotIdentity.address(ticket.account.address)
            for event in page.events {
                guard event.from == owner || event.to == owner, event.timestamp.isFinite, event.height > 0,
                      let token = event.token, token.reference == event.reference else { throw StoreError.conflictingIdentity }
                _ = try AtomicAmount(event.amount)
                _ = try Self.polkadotAsset(token, db: db)
                try db.execute(sql: "INSERT OR REPLACE INTO polkadotEvents(accountID,id,transactionID,detail) VALUES(?,?,?,?)", arguments: [ticket.account.id, event.id, event.transaction, try JSONEncoder().encode(event)])
            }
            for transaction in Set(page.events.map(\.transaction)) {
                let events = try Data.fetchAll(db, sql: "SELECT detail FROM polkadotEvents WHERE accountID=? AND transactionID=? ORDER BY id", arguments: [ticket.account.id, transaction]).map { try JSONDecoder().decode(PolkadotEvent.self, from: $0) }
                guard let first = events.first else { continue }
                let journalID=try String.fetchOne(db,sql:"SELECT sends.transactionID FROM polkadotSendPlans JOIN sends ON sends.id=polkadotSendPlans.sendID WHERE ledgerID=? LIMIT 1",arguments:[transaction])
                let txID = journalID ?? "polkadot:" + transaction
                let success = events.first(where: { $0.id.hasPrefix("extrinsic:") })?.successful ?? true
                let journal=journalID == nil ? nil:try TransactionRecord.fetchOne(db,key:txID)
                try TransactionRecord(id: txID, networkID: "polkadot", hash: journal?.hash ?? transaction, state: journal?.state ?? (success ? "confirmed" : "failed"), blockHeight: first.height, timestamp: first.timestamp, feeAtomic: journal?.feeAtomic, updatedAt: Date().timeIntervalSince1970).upsert(db)
                let transfers = events.filter { !$0.id.hasPrefix("extrinsic:") }
                // Preserve the reviewed payment until transfer events arrive;
                // an extrinsic-only indexer row has no asset or amount details.
                if journal != nil, transfers.isEmpty { continue }
                try db.execute(sql: "DELETE FROM activity WHERE accountID=? AND transactionID=?", arguments: [ticket.account.id, txID])
                for event in transfers.isEmpty ? Array(events.prefix(1)) : transfers {
                    let selfTransfer = event.from == owner && event.to == owner
                    try ActivityRecord(id: ticket.account.id + ":polkadot:" + event.id, walletID: ticket.account.walletID, accountID: ticket.account.id, networkID: "polkadot", transactionID: txID, assetID: "polkadot:" + event.reference, direction: selfTransfer ? "self" : event.from == owner ? "outgoing" : "incoming", amountAtomic: event.amount, counterparty: event.from == owner ? event.to : event.from, timestamp: event.timestamp).upsert(db)
                }
            }
            if advance {
                let lower = try Int64.fetchOne(db, sql: "SELECT lowerHeight FROM polkadotHistory WHERE accountID=? AND stream=?", arguments: [ticket.account.id, stream]) ?? 0
                let complete = page.next == nil || page.oldestHeight.map { $0 <= lower } == true
                let saved = try Int64.fetchOne(db, sql: "SELECT observedHeight FROM polkadotHistory WHERE accountID=? AND stream=?", arguments: [ticket.account.id, stream]) ?? 0
                let observed = max(saved, page.events.map(\.height).max() ?? 0)
                // Indexers can trail the finalized node. Only advance past
                // events actually indexed, retaining a one-block overlap.
                try db.execute(sql: "UPDATE polkadotHistory SET page=?,observedHeight=? WHERE accountID=? AND stream=?", arguments: [complete ? -1 : page.next!, observed, ticket.account.id, stream])
                if complete {
                    try db.execute(sql: "UPDATE polkadotHistory SET upperHeight=? WHERE accountID=? AND stream=?", arguments: [max(lower, observed - 1, 0), ticket.account.id, stream])
                }
            }
        }
    }
    public func commitPolkadotPrices(_ prices: [PolkadotPrice], ticket: PolkadotSyncTicket) async throws {
        try await pool.write { db in
            try Self.validatePolkadot(ticket, db: db)
            for price in prices {
                try Validation.price(price.usd)
                guard price.observedAt.timeIntervalSince1970.isFinite else { throw StoreError.invalidValue("price time") }
                if try AssetRecord.fetchOne(db, key: "polkadot:" + price.reference) != nil {
                    try db.execute(sql: "INSERT INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt) SELECT networkID,reference,'polkadot.market',decimals,? FROM assets WHERE id=? ON CONFLICT(networkID,reference,source) DO UPDATE SET decimals=excluded.decimals,observedAt=excluded.observedAt", arguments: [price.observedAt.timeIntervalSince1970, "polkadot:" + price.reference])
                    try db.execute(sql: "UPDATE polkadotHoldings SET verified=1 WHERE accountID=? AND reference=?", arguments: [ticket.account.id, price.reference])
                    try PriceRecord(assetID: "polkadot:" + price.reference, currency: "USD", value: price.usd, observedAt: price.observedAt.timeIntervalSince1970, source: price.source).upsert(db)
                }
            }
        }
    }
}
