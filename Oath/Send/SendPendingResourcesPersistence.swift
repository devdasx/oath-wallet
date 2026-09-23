import Foundation
import GRDB

extension WalletDatabase {
    func pendingSendSpendResources(accountID: String) async throws -> Set<SendSpendResource> {
        try await pool.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT kind, value FROM sendPendingResources WHERE accountID = ?
                """, arguments: [accountID])
            return try Set(rows.map { row in
                guard let kind = SendSpendResource.Kind(rawValue: row["kind"]) else {
                    throw WalletDataStoreError.invalidState
                }
                return SendSpendResource(kind: kind, value: row["value"])
            })
        }
    }

    /// Used by coin control as well as review/submission. Scope to the wallet
    /// and network, including HD addresses that differ from the account address.
    func pendingBitcoinSpendResources(
        walletID: String?, networkID: String, accountAddress: String
    ) async throws -> Set<SendSpendResource> {
        try await pool.read { database in
            let rows = try Row.fetchAll(database, sql: """
                SELECT r.value FROM sendPendingResources r
                JOIN walletAccounts a ON a.id = r.accountID
                WHERE r.kind = 'outpoint' AND a.networkID = ?
                  AND ((? IS NOT NULL AND a.walletID = ?) OR (? IS NULL AND a.address = ?))
                """, arguments: [networkID, walletID, walletID, walletID, accountAddress])
            return Set(rows.map { SendSpendResource(kind: .outpoint, value: $0["value"]) })
        }
    }

    static func persistPendingSendResources(
        reservation: SendSpendReservation,
        receipt: SendTransactionReceipt,
        database: Database
    ) throws {
        // Old receipts intentionally retain the old lock until their exact
        // transaction can be reconciled. Missing evidence is never an unlock.
        guard !receipt.spendResources.isEmpty else { return }
        let hash = normalizedSendHash(receipt.transactionHash, networkID: receipt.networkID)
        let resources = receipt.spendResources.union([
            SendSpendResource(kind: .transactionID, value: hash)
        ])
        for resource in resources {
            guard !resource.value.isEmpty else { throw WalletDataStoreError.invalidState }
            if let owner = try String.fetchOne(database, sql: """
                SELECT reservationID FROM sendPendingResources
                WHERE accountID = ? AND kind = ? AND value = ?
                """, arguments: [reservation.accountID, resource.kind.rawValue, resource.value]),
               owner != reservation.reservationID {
                throw SendTransactionSubmissionError.spendAlreadyReserved(
                    networkID: reservation.networkID, stateCode: "resource_in_use"
                )
            }
        }
        try database.execute(sql: """
            INSERT OR IGNORE INTO sendPendingSubmissions
                (reservationID, accountID, walletID, networkID, transactionHash,
                 normalizedTransactionHash, fromAddress, createdAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [reservation.reservationID, reservation.accountID,
                reservation.walletID, reservation.networkID, receipt.transactionHash,
                hash, receipt.fromAddress, receipt.submittedAt.timeIntervalSince1970])
        // A reservation cannot be silently repurposed for another signed payload.
        guard try String.fetchOne(database, sql: """
            SELECT normalizedTransactionHash FROM sendPendingSubmissions WHERE reservationID = ?
            """, arguments: [reservation.reservationID]) == hash else {
            throw SendSpendReservationStoreError.staleReservation
        }
        for resource in resources {
            try database.execute(sql: """
                INSERT OR IGNORE INTO sendPendingResources(reservationID, accountID, kind, value)
                VALUES (?, ?, ?, ?)
                """, arguments: [reservation.reservationID, reservation.accountID,
                    resource.kind.rawValue, resource.value])
        }
    }

    /// End the in-flight mutex only after the actual submission attempt exits.
    /// Durable resource claims survive both unknown outcomes and activity-save failures.
    func finishSendSpendSubmission(_ reservation: SendSpendReservation) async throws {
        try await pool.write { database in
            try database.execute(sql: """
                DELETE FROM sendSpendReservations
                WHERE accountID = ? AND reservationID = ?
                  AND EXISTS (SELECT 1 FROM sendPendingSubmissions p
                              WHERE p.reservationID = sendSpendReservations.reservationID)
                """, arguments: [reservation.accountID, reservation.reservationID])
        }
    }

    func pendingSendSubmissionEvidence(accountID: String) async throws -> [SendSpendReservationEvidence] {
        try await pool.read { database in
            try Row.fetchAll(database, sql: """
                SELECT * FROM sendPendingSubmissions WHERE accountID = ? ORDER BY createdAt
                """, arguments: [accountID]).map { row in
                    SendSpendReservationEvidence(
                        reservationID: row["reservationID"], accountID: row["accountID"],
                        walletID: row["walletID"], networkID: row["networkID"],
                        state: .submissionStarted, transactionHash: row["transactionHash"],
                        fromAddress: row["fromAddress"], createdAt: Date(timeIntervalSince1970: row["createdAt"])
                    )
                }
        }
    }

    static func deletePendingSendResources(receipt: SendTransactionReceipt, database: Database) throws {
        try database.execute(sql: """
            DELETE FROM sendPendingSubmissions
            WHERE accountID = ? AND networkID = ? AND normalizedTransactionHash = ?
            """, arguments: [receipt.accountID, receipt.networkID,
                normalizedSendHash(receipt.transactionHash, networkID: receipt.networkID)])
    }
}
