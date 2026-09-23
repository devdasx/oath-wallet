import Foundation
import GRDB

struct AssetLogoDatabaseEntry: Sendable {
    let payload: Data
    let expiresAt: Double
    let etag: String?
    let lastModified: String?
}

extension WalletDatabase {
    private static var assetLogoCacheProvider: String {
        "asset-logo"
    }

    private static var maximumAssetLogoCacheEntryCount: Int {
        4_000
    }

    private static var maximumAssetLogoCachePayloadBytes: Int {
        128 * 1_024 * 1_024
    }

    func assetLogoCacheEntry(
        for url: URL
    ) async throws -> AssetLogoDatabaseEntry? {
        let cacheKey = Self.assetLogoCacheKey(for: url)
        return try await pool.read { database in
            guard let record = try DBAPICacheRecord.fetchOne(
                database,
                key: cacheKey
            ), record.provider == Self.assetLogoCacheProvider else {
                return nil
            }
            return AssetLogoDatabaseEntry(
                payload: record.payload,
                expiresAt: record.expiresAt,
                etag: record.etag,
                lastModified: record.lastModified
            )
        }
    }

    func storeAssetLogoCacheEntry(
        for url: URL,
        payload: Data,
        lifetime: TimeInterval,
        etag: String?,
        lastModified: String?
    ) async throws {
        guard !isPerformingAppReset() else { return }

        let now = Date().timeIntervalSince1970
        let provider = Self.assetLogoCacheProvider
        let cacheKey = Self.assetLogoCacheKey(for: url)
        let endpoint = url.absoluteString
        let expiresAt = now + max(0, lifetime)

        try await pool.write { database in
            guard !self.isPerformingAppReset() else { return }

            try DBAPICacheRecord(
                cacheKey: cacheKey,
                provider: provider,
                endpoint: endpoint,
                payload: payload,
                createdAt: now,
                expiresAt: expiresAt,
                etag: etag,
                lastModified: lastModified
            ).save(database)
            try Self.pruneAssetLogoCache(database)
        }
    }

    func removeAssetLogoCacheEntry(for url: URL) async throws {
        let cacheKey = Self.assetLogoCacheKey(for: url)
        try await pool.write { database in
            try database.execute(
                sql: """
                DELETE FROM apiCache
                WHERE cacheKey = ? AND provider = ?
                """,
                arguments: [
                    cacheKey,
                    Self.assetLogoCacheProvider
                ]
            )
        }
    }

    func removeAllAssetLogoCacheEntries() async throws {
        try await pool.write { database in
            try database.execute(
                sql: "DELETE FROM apiCache WHERE provider = ?",
                arguments: [Self.assetLogoCacheProvider]
            )
        }
    }

    private static func assetLogoCacheKey(for url: URL) -> String {
        "asset-logo:\(url.absoluteString)"
    }

    private static func pruneAssetLogoCache(
        _ database: Database
    ) throws {
        let rows = try Row.fetchAll(
            database,
            sql: """
            SELECT cacheKey, LENGTH(payload) AS payloadByteCount
            FROM apiCache
            WHERE provider = ?
            ORDER BY createdAt DESC, cacheKey DESC
            """,
            arguments: [assetLogoCacheProvider]
        )

        var retainedEntryCount = 0
        var retainedPayloadBytes = 0
        var keysToRemove: [String] = []
        keysToRemove.reserveCapacity(
            max(0, rows.count - maximumAssetLogoCacheEntryCount)
        )

        for row in rows {
            let cacheKey: String = row["cacheKey"]
            let payloadByteCount: Int = row["payloadByteCount"]
            let fitsEntryLimit =
                retainedEntryCount < maximumAssetLogoCacheEntryCount
            let fitsPayloadLimit =
                payloadByteCount
                    <= maximumAssetLogoCachePayloadBytes
                        - retainedPayloadBytes

            if fitsEntryLimit && fitsPayloadLimit {
                retainedEntryCount += 1
                retainedPayloadBytes += payloadByteCount
            } else {
                keysToRemove.append(cacheKey)
            }
        }

        guard !keysToRemove.isEmpty else { return }

        let placeholders = Array(
            repeating: "?",
            count: keysToRemove.count
        ).joined(separator: ",")
        var arguments = StatementArguments(keysToRemove)
        arguments += [assetLogoCacheProvider]
        try database.execute(
            sql: """
            DELETE FROM apiCache
            WHERE cacheKey IN (\(placeholders))
              AND provider = ?
            """,
            arguments: arguments
        )
    }
}
