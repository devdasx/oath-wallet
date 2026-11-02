import Foundation
import GRDB

/// Versioned public provider data. Each consumer validates its own payload.
/// Wallet identity, account addresses and secrets must never enter this cache.
public struct MarketCacheEntry: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "publicMarketCache"
    public let key: String
    public let source: String
    public let payload: Data
    public let fetchedAt: Double

    public init(key: String, source: String, payload: Data, fetchedAt: Double) {
        self.key = key; self.source = source; self.payload = payload; self.fetchedAt = fetchedAt
    }
}

extension OathDatabase {
    public func marketCache(key: String) async throws -> MarketCacheEntry? {
        try await pool.read { try MarketCacheEntry.fetchOne($0, key: key) }
    }

    /// Publish the cached quote and the portfolio's USD price atomically.
    /// Returns the observation that won the write transaction. A slower public
    /// provider response is a successful no-op, not a failed account sync. Keep
    /// the winner's payload, source and timestamp together so callers cannot
    /// publish an older value or activate error backoff after this race.
    @discardableResult
    public func saveMarketCache(_ entry: MarketCacheEntry, price: PriceRecord? = nil) async throws -> MarketCacheEntry {
        guard !entry.key.isEmpty, entry.key.count <= 512,
              !entry.source.isEmpty, entry.source.count <= 200,
              !entry.payload.isEmpty, entry.payload.count <= 2_000_000,
              entry.fetchedAt.isFinite, entry.fetchedAt > 0 else { throw StoreError.invalidValue("market cache") }
        if let price {
            try Validation.price(price.value)
            guard price.currency == "USD", price.observedAt == entry.fetchedAt,
                  price.source == entry.source else { throw StoreError.invalidValue("market quote") }
        }
        return try await pool.write { db in
            if let previous = try MarketCacheEntry.fetchOne(db, key: entry.key), previous.fetchedAt > entry.fetchedAt {
                return previous
            }
            try entry.upsert(db)
            try HistorySafety.ingestCatalog(entry, db: db)
            if let price {
                try price.upsert(db)
                // Keep a bounded quote history; chart candles have a separate cache.
                try db.execute(sql: """
                    DELETE FROM prices WHERE assetID=? AND currency='USD' AND observedAt NOT IN (
                        SELECT observedAt FROM prices WHERE assetID=? AND currency='USD'
                        ORDER BY observedAt DESC LIMIT 256)
                    """, arguments: [price.assetID, price.assetID])
            }
            return entry
        }
    }

    public func assetHistory(walletID: String, accountID: String, assetID: String,
                             before: HistoryCursor? = nil, limit: Int = 50) async throws -> [HistoryEntry] {
        try await pool.read { try Self.readAssetHistory($0, walletID: walletID, accountID: accountID, assetID: assetID,
                                                       before: before, limit: Self.pageSize(limit)) }
    }

    /// Keep the visible history window current as background pages commit.
    /// The UI grows this window explicitly, fifty rows at a time.
    public func observeAssetHistory(walletID: String, accountID: String, assetID: String,
                                    limit: Int = 51) -> AsyncThrowingStream<[HistoryEntry], Error> {
        stream { try Self.readAssetHistory($0, walletID: walletID, accountID: accountID, assetID: assetID,
                                           before: nil, limit: max(1, limit)) }
    }

    private static func readAssetHistory(_ db: Database, walletID: String, accountID: String, assetID: String,
                                         before: HistoryCursor?, limit: Int) throws -> [HistoryEntry] {
            var sql = """
                SELECT a.id,a.accountID,a.networkID,a.transactionID,a.assetID,a.direction,
                       a.amountAtomic,a.counterparty,a.sortTimestamp AS timestamp,COALESCE(e.outcome,t.state) AS state,t.hash
                FROM visibleActivity a JOIN transactions t ON t.id=a.transactionID JOIN walletAccounts ownerAccount ON ownerAccount.id=a.accountID
                LEFT JOIN transactionEvidence e ON e.accountID=a.accountID AND e.transactionID=a.transactionID
                WHERE a.walletID=? AND a.accountID=? AND a.assetID=?
                AND (a.networkID<>'solana' OR EXISTS (SELECT 1 FROM solanaActivity sa WHERE sa.activityID=a.id
                    AND sa.owner=COALESCE((SELECT address FROM solanaReceiveAddresses WHERE accountID=a.accountID AND isSelected=1),ownerAccount.address)))
                """
            var args: StatementArguments = [walletID, accountID, assetID]
            if let before { sql += " AND (a.sortTimestamp,a.id) < (?,?)"; args += [before.timestamp, before.id] }
            sql += " ORDER BY a.sortTimestamp DESC,a.id DESC LIMIT ?"; args += [limit]
            return try HistoryEntry.fetchAll(db, sql: sql, arguments: args).map { try Self.projectSelfTransferFee($0, db: db) }
    }
}
