import Foundation
import GRDB
@testable import Aperture

extension DeviceMigrationProtocolTests {
    func seedSilentPaymentSecrets(
        in database: WalletDatabase,
        vault: WalletSecretVault
    ) async throws -> [String] {
        let accountReference = try vault.store(
            Data("stale-silent-account".utf8),
            kind: .bitcoinSilentPaymentAccount
        )
        let outputReference = try vault.store(
            Data("stale-silent-output".utf8),
            kind: .bitcoinSilentPaymentOutput
        )
        let now = Date().timeIntervalSince1970
        try await database.pool.write { db in
            try DBWalletRecord(
                id: "stale-silent-wallet",
                profileID: WalletDatabase.defaultProfileID,
                name: "Stale Wallet",
                kind: DatabaseWalletKind.created.rawValue,
                secretKeyReference: nil,
                isSelected: true,
                sortOrder: 0,
                createdAt: now,
                updatedAt: now,
                lastOpenedAt: now,
                archivedAt: nil
            ).insert(db)
            try DBBitcoinSilentPaymentAccountRecord(
                walletID: "stale-silent-wallet",
                address: "stale-silent-address",
                scanPublicKey: Data(repeating: 2, count: 33),
                spendPublicKey: Data(repeating: 3, count: 33),
                keychainReference: accountReference,
                birthHeight: 709_632,
                lastScanHeight: 709_631,
                balanceIsAuthoritative: false,
                createdAt: now,
                updatedAt: now
            ).insert(db)
            let outputKey = Data(repeating: 4, count: 32)
            try DBBitcoinSilentPaymentOutputRecord(
                walletID: "stale-silent-wallet",
                transactionHash: String(repeating: "ab", count: 32),
                outputIndex: 0,
                valueAtomic: "1",
                scriptPubKey: Data([0x51, 0x20]) + outputKey,
                outputPublicKey: outputKey,
                keychainReference: outputReference,
                blockHeight: 800_000,
                blockTimestamp: now,
                isSpent: false,
                spentByTransactionHash: nil,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        }
        return [accountReference, outputReference]
    }

    func secretReferencesAreMissing(
        _ references: [String],
        vault: WalletSecretVault
    ) -> Bool {
        references.allSatisfy { reference in
            do {
                _ = try vault.data(reference: reference)
                return false
            } catch WalletSecretVaultError.itemNotFound {
                return true
            } catch {
                return false
            }
        }
    }

    func databaseRowCounts(at url: URL) throws -> [String: Int] {
        let queue = try DatabaseQueue(path: url.path)
        return try queue.read { database in
            try databaseRowCounts(in: database)
        }
    }

    func databaseRowCounts(
        in database: Database
    ) throws -> [String: Int] {
        let tableNames = try String.fetchAll(
            database,
            sql: """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
              AND name <> 'grdb_migrations'
            ORDER BY name
            """
        )
        return try Dictionary(
            uniqueKeysWithValues: tableNames.map { tableName in
                let escaped = tableName.replacingOccurrences(
                    of: "\"",
                    with: "\"\""
                )
                let count = try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM \"\(escaped)\""
                ) ?? 0
                return (tableName, count)
            }
        )
    }
}
