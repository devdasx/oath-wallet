import Foundation
import GRDB
import OathDiagnostics

/// Older Solana decoders selected Double.init(bitPattern:) for UInt64 Unix
/// seconds. SQLite and Codable retained those bits, so recovery is exact and
/// offline: never substitute the sync time or erase/re-fetch a wallet's history.
enum SolanaTimestampRepair {
    static func recoveredSeconds(_ timestamp: Double) -> Double? {
        // Normal timestamps and the zero/absent-time sentinel are untouched.
        // Limit the inverse conversion to seconds within the Gregorian calendar
        // through year 9999; arbitrary subnormal doubles are not date evidence.
        guard timestamp > 0, timestamp.isSubnormal,
              timestamp.bitPattern <= 253_402_300_799 else { return nil }
        return Double(timestamp.bitPattern)
    }

    static func migrate(_ db: Database) throws {
        // An interrupted reset must finish erasing the entire wallet ledger.
        // Do not bypass its mutation guards to repair data scheduled for deletion.
        guard try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key='walletReset'") == nil else { return }
        do {
            for table in ["transactions", "activity"] {
                var after: Int64 = 0
                while true {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT rowid AS repairRowID,timestamp FROM \(table)
                        WHERE rowid>? AND networkID='solana' AND timestamp>0 AND timestamp<?
                        ORDER BY rowid LIMIT 128
                        """, arguments: [after, Double.leastNormalMagnitude])
                    guard !rows.isEmpty else { break }
                    for row in rows {
                        let rowID: Int64 = row["repairRowID"]
                        after = rowID
                        guard let timestamp = recoveredSeconds(row["timestamp"]) else { continue }
                        // Existing activity triggers update the indexed sortTimestamp
                        // in this same migration transaction, preserving send evidence.
                        try db.execute(sql: "UPDATE \(table) SET timestamp=? WHERE rowid=?", arguments: [timestamp, rowID])
                    }
                }
            }

            // Repair cached receipts as well, or a subsequent refresh would copy
            // the old value back into the ledger. Keep every other payload field.
            var after: Int64 = 0
            while true {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT rowid AS repairRowID,detail FROM solanaTransactions
                    WHERE rowid>? ORDER BY rowid LIMIT 16
                    """, arguments: [after])
                guard !rows.isEmpty else { break }
                for row in rows {
                    let rowID: Int64 = row["repairRowID"]
                    after = rowID
                    let repaired: Data?
                    do {
                        repaired = try repairedDetail(row["detail"])
                    } catch {
                        // A pre-existing malformed optional receipt must not block
                        // opening the wallet. Preserve it and report without payloads.
                        OathDiagnostics.record(error, component: "storage", operation: "repair_solana_cached_timestamp", context: ["chain": "solana"])
                        continue
                    }
                    if let repaired {
                        try db.execute(sql: "UPDATE solanaTransactions SET detail=? WHERE rowid=?", arguments: [repaired, rowID])
                    }
                }
            }
        } catch {
            OathDiagnostics.record(error, component: "storage", operation: "migrate_solana_timestamps", context: ["chain": "solana"])
            throw error // GRDB rolls back the entire migration, including its marker.
        }
    }

    private static func repairedDetail(_ data: Data) throws -> Data? {
        guard var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.invalidValue("solana timestamp cache")
        }
        guard let value = fields["timestamp"] as? NSNumber,
              let timestamp = recoveredSeconds(value.doubleValue) else { return nil }
        fields["timestamp"] = timestamp
        return try JSONSerialization.data(withJSONObject: fields)
    }
}
