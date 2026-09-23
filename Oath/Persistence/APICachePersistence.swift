import Foundation
import GRDB

extension WalletDatabase {
    func cacheAPIResponse(
        key: String,
        provider: String,
        endpoint: String,
        payload: Data,
        lifetime: TimeInterval,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await pool.write { database in
            try DBAPICacheRecord(
                cacheKey: key,
                provider: provider,
                endpoint: endpoint,
                payload: payload,
                createdAt: now,
                expiresAt: now + max(0, lifetime),
                etag: etag,
                lastModified: lastModified
            ).save(database)
        }
    }

    func cachedAPIResponse(key: String) async throws -> Data? {
        let now = Date().timeIntervalSince1970
        return try await pool.read { database in
            guard let record = try DBAPICacheRecord.fetchOne(
                database,
                key: key
            ), record.expiresAt > now else {
                return nil
            }
            return record.payload
        }
    }
}
