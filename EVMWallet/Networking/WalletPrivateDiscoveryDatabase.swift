import Foundation
import GRDB

extension WalletDatabase {
    func privateDiscoveryWalletIDs() async throws -> [String] {
        try await pool.read { database in
            try Self.privateDiscoveryWalletIDs(database: database)
        }
    }

    func privateDiscoveryWalletIDsObservation()
        -> AsyncValueObservation<[String]> {
        ValueObservation.tracking { database in
            try Self.privateDiscoveryWalletIDs(database: database)
        }
        .removeDuplicates()
        .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func privateDiscoveryWalletIDs(
        database: Database
    ) throws -> [String] {
        try String.fetchAll(
            database,
            sql: """
            SELECT id
            FROM wallets
            WHERE profileID = ?
              AND archivedAt IS NULL
              AND kind IN (?, ?)
            ORDER BY sortOrder, createdAt, id
            """,
            arguments: [
                defaultProfileID,
                DatabaseWalletKind.created.rawValue,
                DatabaseWalletKind.importedRecoveryPhrase.rawValue,
            ]
        )
    }
}
