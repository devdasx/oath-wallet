import Foundation
import GRDB

struct EVMTransactionReconciliationResult {
    let recordID: String
    let existingRecord: DBTransactionRecord?
    let retainedAmountAtomic: String?
}

private struct EVMTransactionIdentity: Hashable {
    let accountID: String
    let networkID: String
    let normalizedHash: String
    let assetID: String?
}

struct EVMTransactionMetadataMergeReport {
    let notesMoved: Int
    let tagsMoved: Int
    let notificationsMoved: Int
}

extension WalletDatabase {
    static func reconcileSubmittedEVMTransaction(
        generatedRecordID: String,
        accountID: String,
        networkID: String,
        normalizedHash: String,
        assetID: String?,
        providerDirection: String,
        providerAmountText: String,
        database: Database
    ) throws -> EVMTransactionReconciliationResult {
        guard providerDirection == "outgoing" || providerDirection == "self"
        else {
            return try unreconciledEVMResult(
                recordID: generatedRecordID,
                database: database
            )
        }

        let candidates = try localSendCandidates(
            accountID: accountID,
            networkID: networkID,
            normalizedHash: normalizedHash,
            assetID: assetID,
            database: database
        )
        let exactMatches = candidates.filter {
            equalAmountMagnitude(
                $0.assetAmount,
                providerAmountText
            )
        }

        guard exactMatches.count == 1, let local = exactMatches.first else {
            return try unreconciledEVMResult(
                recordID: generatedRecordID,
                database: database
            )
        }

        let localTransfer = try primaryTransfer(
            transactionID: local.id,
            database: database
        )
        let providerDuplicate =
            generatedRecordID == local.id
                ? nil
                : try DBTransactionRecord.fetchOne(
                    database,
                    key: generatedRecordID
                )
        if providerDuplicate != nil {
            _ = try mergeTransactionMetadata(
                sourceID: generatedRecordID,
                destinationID: local.id,
                database: database
            )
            _ = try DBTransactionRecord.deleteOne(
                database,
                key: generatedRecordID
            )
        }
        return EVMTransactionReconciliationResult(
            recordID: local.id,
            existingRecord: local,
            retainedAmountAtomic: localTransfer?.amountAtomic
        )
    }

    static func repairHistoricalEVMTransactionDuplicates(
        database: Database
    ) throws {
        var localRows = try DBTransactionRecord
            .filter(sql: "id LIKE 'send:%'")
            .fetchAll(database)

        let groupedLocalRows = Dictionary(
            grouping: localRows,
            by: evmIdentity
        )
        for rows in groupedLocalRows.values where rows.count > 1 {
            let sorted = rows.sorted(by: canonicalLocalOrder)
            guard let canonical = sorted.first else { continue }
            for duplicate in sorted.dropFirst() {
                _ = try mergeTransactionMetadata(
                    sourceID: duplicate.id,
                    destinationID: canonical.id,
                    database: database
                )
                _ = try DBTransactionRecord.deleteOne(
                    database,
                    key: duplicate.id
                )
            }
        }

        localRows = try DBTransactionRecord
            .filter(sql: "id LIKE 'send:%'")
            .fetchAll(database)
        for local in localRows {
            let candidates = try providerCandidates(
                matching: local,
                database: database
            )
            let exactMatches = candidates.filter {
                equalAmountMagnitude($0.assetAmount, local.assetAmount)
            }
            guard exactMatches.count == 1, let provider = exactMatches.first
            else {
                if exactMatches.count > 1 {
                }
                continue
            }

            let localTransfer = try primaryTransfer(
                transactionID: local.id,
                database: database
            )
            let providerTransfer = try primaryTransfer(
                transactionID: provider.id,
                database: database
            )
            _ = try mergeTransactionMetadata(
                sourceID: provider.id,
                destinationID: local.id,
                database: database
            )
            try migratedRecord(
                local: local,
                provider: provider
            ).save(database)
            if let providerTransfer {
                try migratedTransfer(
                    localID: local.id,
                    localTransfer: localTransfer,
                    providerTransfer: providerTransfer
                ).save(database)
            }
            _ = try DBTransactionRecord.deleteOne(
                database,
                key: provider.id
            )
        }

    }

    private static func unreconciledEVMResult(
        recordID: String,
        database: Database
    ) throws -> EVMTransactionReconciliationResult {
        let existing = try DBTransactionRecord.fetchOne(
            database,
            key: recordID
        )
        let transfer = try primaryTransfer(
            transactionID: recordID,
            database: database
        )
        return EVMTransactionReconciliationResult(
            recordID: recordID,
            existingRecord: existing,
            retainedAmountAtomic: transfer?.amountAtomic
        )
    }

    private static func localSendCandidates(
        accountID: String,
        networkID: String,
        normalizedHash: String,
        assetID: String?,
        database: Database
    ) throws -> [DBTransactionRecord] {
        try DBTransactionRecord
            .filter(Column("accountID") == accountID)
            .filter(Column("networkID") == networkID)
            .filter(Column("normalizedTransactionHash") == normalizedHash)
            .filter(Column("assetID") == assetID)
            .filter(sql: "id LIKE 'send:%'")
            .fetchAll(database)
    }

    private static func providerCandidates(
        matching local: DBTransactionRecord,
        database: Database
    ) throws -> [DBTransactionRecord] {
        try DBTransactionRecord
            .filter(Column("accountID") == local.accountID)
            .filter(Column("networkID") == local.networkID)
            .filter(
                Column("normalizedTransactionHash")
                    == local.normalizedTransactionHash
            )
            .filter(Column("assetID") == local.assetID)
            .filter(["outgoing", "self"].contains(Column("direction")))
            .filter(sql: "id NOT LIKE 'send:%'")
            .fetchAll(database)
    }

    private static func primaryTransfer(
        transactionID: String,
        database: Database
    ) throws -> DBTransactionTransferRecord? {
        try DBTransactionTransferRecord
            .filter(Column("transactionID") == transactionID)
            .order(Column("logIndex"), Column("id"))
            .fetchOne(database)
    }

    private static func mergeTransactionMetadata(
        sourceID: String,
        destinationID: String,
        database: Database
    ) throws -> EVMTransactionMetadataMergeReport {
        guard sourceID != destinationID else {
            return EVMTransactionMetadataMergeReport(
                notesMoved: 0,
                tagsMoved: 0,
                notificationsMoved: 0
            )
        }

        let sourceNote = try DBTransactionNoteRecord.fetchOne(
            database,
            key: sourceID
        )
        let destinationNote = try DBTransactionNoteRecord.fetchOne(
            database,
            key: destinationID
        )
        var notesMoved = 0
        if destinationNote == nil, let sourceNote {
            try DBTransactionNoteRecord(
                transactionID: destinationID,
                note: sourceNote.note,
                createdAt: sourceNote.createdAt,
                updatedAt: sourceNote.updatedAt
            ).save(database)
            notesMoved = 1
        }

        let destinationTagCountBefore = try DBTransactionTagRecord
            .filter(Column("transactionID") == destinationID)
            .fetchCount(database)
        try database.execute(
            sql: """
            INSERT OR IGNORE INTO transactionTags (transactionID, tagID)
            SELECT ?, tagID
            FROM transactionTags
            WHERE transactionID = ?
            """,
            arguments: [destinationID, sourceID]
        )
        let destinationTagCountAfter = try DBTransactionTagRecord
            .filter(Column("transactionID") == destinationID)
            .fetchCount(database)

        let notificationCount = try DBNotificationRecord
            .filter(Column("relatedTransactionID") == sourceID)
            .fetchCount(database)
        try DBNotificationRecord
            .filter(Column("relatedTransactionID") == sourceID)
            .updateAll(
                database,
                Column("relatedTransactionID").set(to: destinationID)
            )
        return EVMTransactionMetadataMergeReport(
            notesMoved: notesMoved,
            tagsMoved: destinationTagCountAfter - destinationTagCountBefore,
            notificationsMoved: notificationCount
        )
    }

    private static func evmIdentity(
        _ record: DBTransactionRecord
    ) -> EVMTransactionIdentity {
        EVMTransactionIdentity(
            accountID: record.accountID,
            networkID: record.networkID,
            normalizedHash: record.normalizedTransactionHash,
            assetID: record.assetID
        )
    }

    private static func canonicalLocalOrder(
        lhs: DBTransactionRecord,
        rhs: DBTransactionRecord
    ) -> Bool {
        if lhs.firstSeenAt != rhs.firstSeenAt {
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        return lhs.id < rhs.id
    }

    private static func equalAmountMagnitude(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        if let left = ExactDecimalText.canonicalMagnitude(lhs),
           let right = ExactDecimalText.canonicalMagnitude(rhs) {
            return left == right
        }
        guard let left = decimal(lhs), let right = decimal(rhs) else {
            return false
        }
        return magnitude(left) == magnitude(right)
    }

    private static func migratedRecord(
        local: DBTransactionRecord,
        provider: DBTransactionRecord
    ) -> DBTransactionRecord {
        DBTransactionRecord(
            id: local.id,
            accountID: local.accountID,
            networkID: local.networkID,
            transactionHash: provider.transactionHash,
            normalizedTransactionHash: provider.normalizedTransactionHash,
            kind: provider.kind,
            status: provider.status,
            direction: provider.direction,
            fromAddress: provider.fromAddress ?? local.fromAddress,
            toAddress: provider.toAddress ?? local.toAddress,
            counterpartyAddress:
                provider.counterpartyAddress ?? local.counterpartyAddress,
            blockNumber: provider.blockNumber ?? local.blockNumber,
            blockHash: provider.blockHash ?? local.blockHash,
            transactionIndex:
                provider.transactionIndex ?? local.transactionIndex,
            nonce: provider.nonce ?? local.nonce,
            transactionType:
                provider.transactionType ?? local.transactionType,
            timestamp: provider.timestamp ?? local.timestamp,
            assetID: provider.assetID ?? local.assetID,
            assetSymbol: provider.assetSymbol,
            secondaryAssetSymbol:
                provider.secondaryAssetSymbol ?? local.secondaryAssetSymbol,
            assetAmount: provider.assetAmount,
            fiatUSDValue: provider.fiatUSDValue ?? local.fiatUSDValue,
            networkFee: provider.networkFee ?? local.networkFee,
            networkFeeFiatUSDValue:
                provider.networkFeeFiatUSDValue
                ?? local.networkFeeFiatUSDValue,
            networkFeeSymbol:
                provider.networkFeeSymbol ?? local.networkFeeSymbol,
            gasPriceGwei: provider.gasPriceGwei ?? local.gasPriceGwei,
            gasLimit: provider.gasLimit ?? local.gasLimit,
            gasUsed: provider.gasUsed ?? local.gasUsed,
            inputData: provider.inputData ?? local.inputData,
            methodName: provider.methodName ?? local.methodName,
            displayDetail:
                provider.displayDetail.isEmpty
                    ? local.displayDetail
                    : provider.displayDetail,
            displayTime:
                provider.displayTime.isEmpty
                    ? local.displayTime
                    : provider.displayTime,
            firstSeenAt: min(local.firstSeenAt, provider.firstSeenAt),
            updatedAt: max(local.updatedAt, provider.updatedAt)
        )
    }

    private static func migratedTransfer(
        localID: String,
        localTransfer: DBTransactionTransferRecord?,
        providerTransfer: DBTransactionTransferRecord
    ) -> DBTransactionTransferRecord {
        DBTransactionTransferRecord(
            id: "\(localID)|primary",
            transactionID: localID,
            logIndex: providerTransfer.logIndex,
            assetID: providerTransfer.assetID,
            fromAddress:
                providerTransfer.fromAddress ?? localTransfer?.fromAddress,
            toAddress: providerTransfer.toAddress ?? localTransfer?.toAddress,
            direction: providerTransfer.direction,
            amount: providerTransfer.amount,
            amountAtomic:
                providerTransfer.amountAtomic ?? localTransfer?.amountAtomic,
            fiatUSDValue:
                providerTransfer.fiatUSDValue ?? localTransfer?.fiatUSDValue,
            tokenName: providerTransfer.tokenName ?? localTransfer?.tokenName,
            tokenSymbol: providerTransfer.tokenSymbol,
            tokenDecimals:
                providerTransfer.tokenDecimals ?? localTransfer?.tokenDecimals
        )
    }
}
