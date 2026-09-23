import Foundation
import GRDB

enum SendRecordedBroadcastOutcome: Equatable, Sendable {
    case accepted
    case outcomeUnknown
    case executionFailed
    case confirmed

    var transactionStatus: String {
        switch self {
        case .accepted, .outcomeUnknown:
            "pending"
        case .executionFailed:
            "failed"
        case .confirmed:
            "confirmed"
        }
    }

    var displayStatusKey: String {
        switch self {
        case .accepted, .outcomeUnknown:
            "wallet.activity.status.pending"
        case .executionFailed:
            "wallet.activity.status.failed"
        case .confirmed:
            "wallet.activity.status.confirmed"
        }
    }

    var recordsAcceptedRecipient: Bool {
        self == .accepted || self == .confirmed
    }
}

extension WalletDatabase {
    func discardAbandonedSendSpendPreparations() throws {
        try pool.write { database in
            try database.execute(
                sql: """
                DELETE FROM sendSpendReservations
                WHERE state = 'preparing'
                   OR EXISTS (SELECT 1 FROM sendPendingSubmissions p
                              WHERE p.reservationID = sendSpendReservations.reservationID)
                """
            )
        }
    }

    func acquireSendSpendReservation(
        material: SendResolvedSigningMaterial,
        reservationID: String = UUID().uuidString,
        now: Date = Date()
    ) async throws -> SendSpendReservation {
        try await pool.write { database in
            guard
                let network = try DBNetworkRecord.fetchOne(
                    database,
                    key: material.account.networkID
                ),
                network.isMainnet
            else {
                throw WalletDataStoreError.invalidMainnet
            }
            guard
                let account = try DBWalletAccountRecord.fetchOne(
                    database,
                    key: material.account.id
                ),
                account.walletID == material.walletID,
                account.networkID == material.account.networkID,
                account.isEnabled,
                !account.isWatchOnly
            else {
                throw WalletDataStoreError.missingRecord
            }

            try database.execute(sql: """
                DELETE FROM sendPendingSubmissions
                WHERE accountID = ? AND EXISTS (
                    SELECT 1 FROM transactions t
                    WHERE t.accountID = sendPendingSubmissions.accountID
                      AND t.networkID = sendPendingSubmissions.networkID
                      AND t.normalizedTransactionHash = sendPendingSubmissions.normalizedTransactionHash
                      AND t.status IN ('confirmed', 'failed', 'canceled')
                )
                """, arguments: [account.id])

            if let row = try Row.fetchOne(
                database,
                sql: """
                SELECT reservationID, accountID, walletID, networkID,
                       state, transactionHash, fromAddress, createdAt
                FROM sendSpendReservations
                WHERE accountID = ?
                """,
                arguments: [account.id]
            ) {
                let evidence = try Self.sendSpendReservationEvidence(
                    row: row
                )
                if try Self.hasLocallyTerminalTransaction(
                    for: evidence,
                    database: database
                ) {
                    try database.execute(
                        sql: """
                        DELETE FROM sendSpendReservations
                        WHERE accountID = ? AND reservationID = ?
                        """,
                        arguments: [
                            evidence.accountID,
                            evidence.reservationID
                        ]
                    )
                } else {
                    throw SendSpendReservationStoreError
                        .conflict(evidence)
                }
            }

            let timestamp = now.timeIntervalSince1970
            try database.execute(
                sql: """
                INSERT INTO sendSpendReservations (
                    accountID, reservationID, walletID, networkID,
                    state, transactionHash,
                    normalizedTransactionHash, fromAddress,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, 'preparing', NULL, NULL, NULL, ?, ?)
                """,
                arguments: [
                    account.id,
                    reservationID,
                    material.walletID,
                    account.networkID,
                    timestamp,
                    timestamp
                ]
            )
            return SendSpendReservation(
                reservationID: reservationID,
                accountID: account.id,
                walletID: material.walletID,
                networkID: account.networkID,
                database: self
            )
        }
    }

    func markSendSpendSubmissionStarted(
        reservation: SendSpendReservation,
        receipt: SendTransactionReceipt,
        now: Date = Date()
    ) async throws {
        guard receipt.accountID == reservation.accountID,
              receipt.networkID == reservation.networkID,
              !receipt.transactionHash
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
              !receipt.fromAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty else {
            throw WalletDataStoreError.invalidState
        }
        let normalizedHash = Self.normalizedSendHash(
            receipt.transactionHash,
            networkID: receipt.networkID
        )
        try await pool.write { database in
            try Self.persistPendingSendResources(
                reservation: reservation, receipt: receipt, database: database
            )
            try database.execute(
                sql: """
                UPDATE sendSpendReservations
                SET state = 'submissionStarted',
                    transactionHash = ?,
                    normalizedTransactionHash = ?,
                    fromAddress = ?,
                    updatedAt = ?
                WHERE accountID = ?
                  AND reservationID = ?
                  AND walletID = ?
                  AND networkID = ?
                  AND state = 'preparing'
                """,
                arguments: [
                    receipt.transactionHash,
                    normalizedHash,
                    receipt.fromAddress,
                    now.timeIntervalSince1970,
                    reservation.accountID,
                    reservation.reservationID,
                    reservation.walletID,
                    reservation.networkID
                ]
            )
            if database.changesCount == 1 {
                return
            }
            let existing = try Row.fetchOne(
                database,
                sql: """
                SELECT state, normalizedTransactionHash, fromAddress
                FROM sendSpendReservations
                WHERE accountID = ? AND reservationID = ?
                """,
                arguments: [
                    reservation.accountID,
                    reservation.reservationID
                ]
            )
            let state: String? = existing?["state"]
            let existingHash: String? =
                existing?["normalizedTransactionHash"]
            let existingAddress: String? = existing?["fromAddress"]
            guard state == SendSpendReservationState
                    .submissionStarted.rawValue,
                  existingHash == normalizedHash,
                  existingAddress == receipt.fromAddress else {
                throw SendSpendReservationStoreError.staleReservation
            }
        }
    }

    func releaseSendSpendReservation(
        _ reservation: SendSpendReservation,
        onlyIfPreparing: Bool = false
    ) async throws {
        try await pool.write { database in
            if !onlyIfPreparing {
                try database.execute(sql: """
                    DELETE FROM sendPendingSubmissions WHERE reservationID = ? AND accountID = ?
                    """, arguments: [reservation.reservationID, reservation.accountID])
            }
            let stateClause = onlyIfPreparing
                ? " AND state = 'preparing'"
                : ""
            try database.execute(
                sql: """
                DELETE FROM sendSpendReservations
                WHERE accountID = ? AND reservationID = ?\(stateClause)
                """,
                arguments: [
                    reservation.accountID,
                    reservation.reservationID
                ]
            )
        }
    }

    func releaseSendSpendReservation(
        evidence: SendSpendReservationEvidence
    ) async throws {
        try await pool.write { database in
            try database.execute(
                sql: """
                DELETE FROM sendSpendReservations
                WHERE accountID = ? AND reservationID = ?
                """,
                arguments: [
                    evidence.accountID,
                    evidence.reservationID
                ]
            )
        }
    }

    func sendSpendReservationEvidence(
        accountID: String
    ) async throws -> SendSpendReservationEvidence? {
        try await pool.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                SELECT reservationID, accountID, walletID, networkID,
                       state, transactionHash, fromAddress, createdAt
                FROM sendSpendReservations
                WHERE accountID = ?
                """,
                arguments: [accountID]
            ) else {
                return nil
            }
            return try Self.sendSpendReservationEvidence(row: row)
        }
    }

    func recordSubmittedSend(
        receipt: SendTransactionReceipt,
        draft: SendDraft,
        outcome: SendRecordedBroadcastOutcome
    ) async throws -> String {
        try await pool.write { database in
            guard
                let network = try DBNetworkRecord.fetchOne(
                    database,
                    key: receipt.networkID
                ),
                network.isMainnet
            else {
                throw WalletDataStoreError.invalidMainnet
            }
            guard
                let account = try DBWalletAccountRecord.fetchOne(
                    database,
                    key: receipt.accountID
                ),
                account.networkID == receipt.networkID,
                account.isEnabled,
                !account.isWatchOnly
            else {
                throw WalletDataStoreError.missingRecord
            }
            guard
                let asset = try DBAssetRecord.fetchOne(
                    database,
                    key: receipt.assetID
                ),
                asset.networkID == receipt.networkID
            else {
                throw WalletDataStoreError.missingRecord
            }

            let recordID = Self.submittedSendRecordID(
                receipt: receipt
            )
            let now = receipt.submittedAt.timeIntervalSince1970
            let existing = try DBTransactionRecord.fetchOne(
                database,
                key: recordID
            )
            let normalizedHash = Self.normalizedSendHash(
                receipt.transactionHash,
                networkID: receipt.networkID
            )
            try Self.trackSendStatus(receipt, status: outcome.transactionStatus, in: database)
            try DBTransactionRecord(
                id: recordID,
                accountID: account.id,
                networkID: receipt.networkID,
                transactionHash: receipt.transactionHash,
                normalizedTransactionHash: normalizedHash,
                kind: "sent",
                status: outcome.transactionStatus,
                direction: "outgoing",
                fromAddress: receipt.fromAddress,
                toAddress: receipt.toAddress,
                counterpartyAddress: receipt.toAddress,
                blockNumber: nil,
                blockHash: nil,
                transactionIndex: nil,
                nonce: nil,
                transactionType: nil,
                timestamp: now,
                assetID: asset.id,
                assetSymbol: receipt.assetSymbol,
                secondaryAssetSymbol: nil,
                assetAmount: receipt.amount,
                fiatUSDValue: nil,
                networkFee: receipt.networkFee,
                networkFeeFiatUSDValue: nil,
                networkFeeSymbol: receipt.networkFeeSymbol,
                gasPriceGwei: nil,
                gasLimit: nil,
                gasUsed: nil,
                inputData: receipt.networkID == XRPConstants.networkID
                    ? XRPDestinationTag.normalized(draft.request.memo)
                    : nil,
                methodName: receipt.networkID == XRPConstants.networkID
                    && XRPDestinationTag.normalized(draft.request.memo) != nil
                    ? "DestinationTag"
                    : nil,
                displayDetail: receipt.toAddress,
                displayTime: WalletLocalization.string(
                    outcome.displayStatusKey
                ),
                firstSeenAt: existing?.firstSeenAt ?? now,
                updatedAt: now
            ).save(database)

            try DBTransactionTransferRecord(
                id: "\(recordID)|primary",
                transactionID: recordID,
                logIndex: nil,
                assetID: asset.id,
                fromAddress: receipt.fromAddress,
                toAddress: receipt.toAddress,
                direction: "outgoing",
                amount: receipt.amount,
                amountAtomic: receipt.amountAtomic,
                fiatUSDValue: nil,
                tokenName: asset.name,
                tokenSymbol: receipt.assetSymbol,
                tokenDecimals: asset.decimals
            ).save(database)

            if let note = WalletTransactionNote.normalized(draft.note) {
                let existingNote = try DBTransactionNoteRecord.fetchOne(
                    database,
                    key: recordID
                )
                try DBTransactionNoteRecord(
                    transactionID: recordID,
                    note: note,
                    createdAt: existingNote?.createdAt ?? now,
                    updatedAt: now
                ).save(database)
            }
            if outcome.recordsAcceptedRecipient {
                try Self.recordAcceptedSendRecipient(
                    receipt: receipt, draft: draft, asset: asset, walletID: account.walletID, database: database
                )
            }
            if outcome == .executionFailed || outcome == .confirmed {
                try Self.deleteSendSpendReservation(
                    receipt: receipt,
                    database: database
                )
            }
            return recordID
        }
    }

    func updateSubmittedSendStatus(
        receipt: SendTransactionReceipt,
        status: SendTransactionNetworkStatus
    ) async throws -> Bool {
        guard status.isTerminal else { return false }
        return try await pool.write { database in
            guard
                let network = try DBNetworkRecord.fetchOne(
                    database,
                    key: receipt.networkID
                ),
                network.isMainnet
            else {
                throw WalletDataStoreError.invalidMainnet
            }
            guard
                let account = try DBWalletAccountRecord.fetchOne(
                    database,
                    key: receipt.accountID
                ),
                account.networkID == receipt.networkID
            else {
                throw WalletDataStoreError.missingRecord
            }
            let displayTime = WalletLocalization.string(status.localizedKey)
            try database.execute(
                sql: """
                UPDATE transactions
                SET status = ?, displayTime = ?, updatedAt = ?
                WHERE accountID = ?
                  AND networkID = ?
                  AND normalizedTransactionHash IN (?, ?)
                  AND (transactionHash = ? OR (? = 1 AND lower(transactionHash) = lower(?)))
                  AND status = 'pending'
                """,
                arguments: [
                    status.databaseStatus,
                    displayTime,
                    Date().timeIntervalSince1970,
                    receipt.accountID,
                    receipt.networkID,
                    Self.normalizedSendHash(
                        receipt.transactionHash,
                        networkID: receipt.networkID
                    ), receipt.transactionHash.lowercased(), receipt.transactionHash,
                    [SolanaConstants.networkID, SuiConstants.networkID, NEARConstants.networkID]
                        .contains(receipt.networkID) ? 0 : 1, receipt.transactionHash
                ]
            )
            let didUpdateTransaction = database.changesCount > 0
            try database.execute(sql: """
                UPDATE sendStatusTracking SET status = ?
                WHERE accountID = ? AND networkID = ? AND normalizedTransactionHash = ? AND status = 'pending'
                """, arguments: [status.databaseStatus, receipt.accountID, receipt.networkID,
                    Self.normalizedSendHash(receipt.transactionHash, networkID: receipt.networkID)])
            try Self.deleteSendSpendReservation(
                receipt: receipt,
                database: database
            )
            return didUpdateTransaction
        }
    }

    private static func submittedSendRecordID(
        receipt: SendTransactionReceipt
    ) -> String {
        if BitcoinFamilyChain(
            rawValue: receipt.networkID
        ) != nil {
            return "\(receipt.accountID):\(receipt.transactionHash)"
        }
        if receipt.networkID == SolanaConstants.networkID
            || receipt.networkID == TronConstants.networkID
            || receipt.networkID == TONConstants.networkID
            || receipt.networkID == SuiConstants.networkID
            || receipt.networkID == XRPConstants.networkID {
            return "\(receipt.accountID):\(receipt.transactionHash):\(receipt.assetID)"
        }
        return [
            "send",
            receipt.accountID,
            receipt.networkID,
            Self.normalizedSendHash(
                receipt.transactionHash,
                networkID: receipt.networkID
            ),
            receipt.assetID
        ].joined(separator: ":")
    }

    private static func sendSpendReservationEvidence(
        row: Row
    ) throws -> SendSpendReservationEvidence {
        let stateValue: String = row["state"]
        guard let state = SendSpendReservationState(
            rawValue: stateValue
        ) else {
            throw WalletDataStoreError.invalidState
        }
        let createdAt: Double = row["createdAt"]
        return SendSpendReservationEvidence(
            reservationID: row["reservationID"],
            accountID: row["accountID"],
            walletID: row["walletID"],
            networkID: row["networkID"],
            state: state,
            transactionHash: row["transactionHash"],
            fromAddress: row["fromAddress"],
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static func hasLocallyTerminalTransaction(
        for evidence: SendSpendReservationEvidence,
        database: Database
    ) throws -> Bool {
        guard evidence.state == .submissionStarted,
              let transactionHash = evidence.transactionHash else {
            return false
        }
        return try Int.fetchOne(
            database,
            sql: """
            SELECT 1
            FROM transactions
            WHERE accountID = ?
              AND networkID = ?
              AND normalizedTransactionHash = ?
              AND status IN ('confirmed', 'failed', 'canceled')
            LIMIT 1
            """,
            arguments: [
                evidence.accountID,
                evidence.networkID,
                normalizedSendHash(
                    transactionHash,
                    networkID: evidence.networkID
                )
            ]
        ) != nil
    }

    private static func deleteSendSpendReservation(
        receipt: SendTransactionReceipt,
        database: Database
    ) throws {
        try deletePendingSendResources(receipt: receipt, database: database)
        try database.execute(
            sql: """
            DELETE FROM sendSpendReservations
            WHERE accountID = ?
              AND networkID = ?
              AND normalizedTransactionHash = ?
              AND state = 'submissionStarted'
            """,
            arguments: [
                receipt.accountID,
                receipt.networkID,
                normalizedSendHash(
                    receipt.transactionHash,
                    networkID: receipt.networkID
                )
            ]
        )
    }

    static func normalizedSendHash(
        _ hash: String,
        networkID: String
    ) -> String {
        networkID == SolanaConstants.networkID
            || networkID == SuiConstants.networkID
            || networkID == NEARConstants.networkID
            ? hash
            : hash.lowercased()
    }
}

extension WalletDatabase {
    func setTransactionNote(
        transactionID: String,
        note: String?
    ) async throws {
        if let note,
           !WalletTransactionNote.acceptsEditableInput(note) {
            throw WalletDataStoreError.invalidState
        }
        let normalizedNote = WalletTransactionNote.normalized(note)

        try await pool.write { database in
            guard try DBTransactionRecord.fetchOne(
                database,
                key: transactionID
            ) != nil else {
                throw WalletDataStoreError.missingRecord
            }

            guard let normalizedNote else {
                _ = try DBTransactionNoteRecord.deleteOne(
                    database,
                    key: transactionID
                )
                return
            }

            let now = Date().timeIntervalSince1970
            let existing = try DBTransactionNoteRecord.fetchOne(
                database,
                key: transactionID
            )
            try DBTransactionNoteRecord(
                transactionID: transactionID,
                note: normalizedNote,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now
            ).save(database)
        }
    }

    func transactionNote(
        transactionID: String
    ) async throws -> String? {
        try await pool.read { database in
            try DBTransactionNoteRecord.fetchOne(
                database,
                key: transactionID
            )?.note
        }
    }
}
