import Foundation
import GRDB

/// Public network data only. Wallet secrets, addresses and balances never enter this cache.
struct WalletNetworkFeeRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "networkFeeQuotes"
    let networkID: String
    var payload: String?
    var lastAttemptAt: Double
    var lastAttemptSucceeded: Bool

    var quote: SendNetworkFeeQuote? {
        guard let payload, payload.utf8.count <= 16_384 else { return nil }
        return try? JSONDecoder().decode(SendNetworkFeeQuote.self, from: Data(payload.utf8))
    }
}

enum WalletNetworkFeeCachePolicy {
    // Provider expiry describes a fresh sample, not the lifetime of a reviewed
    // transaction. Keep a bounded offline reuse window without changing timestamps.
    static let maximumReuseAge: TimeInterval = 15 * 60
    static let refreshInterval: TimeInterval = 30

    static func canReuse(_ quote: SendNetworkFeeQuote, networkID: String, now: Date = Date()) -> Bool {
        SendNetworkFeeAPIClient.isValidForSessionReuse(quote, expectedNetworkID: networkID)
            && quote.fetchedAt.timeIntervalSince1970.isFinite
            && quote.expiresAt.timeIntervalSince1970.isFinite
            && quote.fetchedAt <= now.addingTimeInterval(60)
            && now.timeIntervalSince(quote.fetchedAt) <= maximumReuseAge
            && quote.provider != SendNetworkFeeAPIClient.builtInDefaultProvider
    }

    static func resolvedQuote(record: WalletNetworkFeeRecord?, networkID: String, now: Date = Date()) throws -> SendNetworkFeeQuote {
        if let record, record.networkID == networkID, let quote = record.quote,
           canReuse(quote, networkID: networkID, now: now) { return quote }
        return try SendNetworkFeeAPIClient.defaultQuote(for: networkID, now: now)
    }
}

extension WalletDatabase {
    static func registerNetworkFeeCacheMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v58_network_fee_quote_cache") { database in
            try database.execute(sql: """
                CREATE TABLE networkFeeQuotes (
                    networkID TEXT PRIMARY KEY NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
                    payload TEXT,
                    lastAttemptAt REAL NOT NULL,
                    lastAttemptSucceeded INTEGER NOT NULL CHECK (lastAttemptSucceeded IN (0, 1))
                );
                """)
        }
    }

    func networkFeeRecord(for networkID: String) async throws -> WalletNetworkFeeRecord? {
        try await pool.read { database in
            try WalletNetworkFeeRecord.fetchOne(database, key: networkID)
        }
    }

    func networkFeeRecords() -> AsyncValueObservation<[WalletNetworkFeeRecord]> {
        ValueObservation.tracking { database in
            try WalletNetworkFeeRecord.fetchAll(database)
        }.values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    func saveNetworkFeeAttempt(networkID: String, quote: SendNetworkFeeQuote?,
                               expectedGeneration: UInt64, now: Date = Date()) async throws {
        guard SendNetworkFeeAPIClient.supportedQuoteNetworkIDs.contains(networkID) else {
            throw SendNetworkFeeAPIError.invalidNetwork
        }
        let validQuote = quote.flatMap {
            WalletNetworkFeeCachePolicy.canReuse($0, networkID: networkID, now: now) ? $0 : nil
        }
        let encoded = try validQuote.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try await pool.write { database in
            guard self.applicationSettingsWriteGate(expectedGeneration: expectedGeneration) == .allowed else { return }
            var previous = try WalletNetworkFeeRecord.fetchOne(database, key: networkID)
            // A late provider result cannot overwrite a newer stored sample.
            if let validQuote, let oldQuote = previous?.quote, oldQuote.fetchedAt > validQuote.fetchedAt { return }
            if let previous, previous.lastAttemptAt > now.timeIntervalSince1970 { return }
            if previous == nil {
                previous = WalletNetworkFeeRecord(networkID: networkID, payload: nil,
                    lastAttemptAt: now.timeIntervalSince1970, lastAttemptSucceeded: false)
            }
            if let encoded { previous?.payload = encoded }
            previous?.lastAttemptAt = now.timeIntervalSince1970
            previous?.lastAttemptSucceeded = validQuote != nil
            try previous?.save(database)
        }
    }
}
