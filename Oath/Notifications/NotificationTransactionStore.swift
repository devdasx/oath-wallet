import Foundation
import GRDB

struct NotificationTransactionContext: Sendable {
    let notification: DBNotificationRecord
    let record: DBTransactionRecord
    let account: DBWalletAccountRecord
    let transaction: WalletTransaction

    var receipt: SendTransactionReceipt {
        let address: String
        if BitcoinFamilyChain(rawValue: record.networkID) != nil {
            address = (record.direction == "incoming" ? transaction.metadata.toAddress : transaction.metadata.fromAddress)
                ?? account.address
        } else {
            address = transaction.metadata.fromAddress ?? account.address
        }
        return SendTransactionReceipt(
            transactionHash: record.transactionHash, accountID: account.id,
            networkID: record.networkID, fromAddress: address,
            toAddress: transaction.metadata.toAddress ?? "", assetID: record.assetID ?? "",
            assetSymbol: record.assetSymbol, amount: record.assetAmount,
            amountAtomic: transaction.assetAmountAtomic ?? "0", networkFee: record.networkFee,
            networkFeeAtomic: nil, networkFeeSymbol: record.networkFeeSymbol ?? "",
            submittedAt: Date(timeIntervalSince1970: record.timestamp ?? record.firstSeenAt)
        )
    }
}

/// Resolves notifications independently of the currently selected wallet.
enum NotificationTransactionStore {
    static func context(for notification: DBNotificationRecord, in db: Database) throws -> NotificationTransactionContext? {
        guard notification.category == "received" || notification.category == "sent" else { return nil }
        let linked = try notification.relatedTransactionID.flatMap { try DBTransactionRecord.fetchOne(db, key: $0) }
        let linkedAccount = try linked.flatMap { try DBWalletAccountRecord.fetchOne(db, key: $0.accountID) }
        guard let walletID = notification.walletID ?? linkedAccount?.walletID,
              let networkID = notification.networkID ?? linked?.networkID,
              let hash = notification.transactionHash ?? linked?.transactionHash,
              let wallet = try DBWalletRecord.fetchOne(db, key: walletID),
              wallet.profileID == notification.profileID, wallet.archivedAt == nil,
              let network = try DBNetworkRecord.fetchOne(db, key: networkID), network.isMainnet else { return nil }
        let candidates = try records(walletID: walletID, networkID: networkID, hash: hash, in: db).filter {
            $0.kind == notification.category
                && (notification.assetSymbol == nil || $0.assetSymbol == notification.assetSymbol)
        }
        // A ticker is insufficient to choose between different token contracts.
        guard Set(candidates.map { $0.assetID ?? "" }).count == 1,
              let record = candidates.first(where: { $0.id == notification.relatedTransactionID }) ?? candidates.first,
              let account = try DBWalletAccountRecord.fetchOne(db, key: record.accountID),
              account.networkID == networkID, account.isEnabled else { return nil }
        var assets: [String: DBAssetRecord] = [:]
        if let id = record.assetID, let asset = try DBAssetRecord.fetchOne(db, key: id) {
            guard asset.networkID == networkID else { return nil }
            assets[id] = asset
        }
        guard !assets.isEmpty || record.assetSymbol == network.nativeSymbol else { return nil }
        let transfer = try DBTransactionTransferRecord.fetchOne(db, key: "\(record.id)|primary")
        let note = try DBTransactionNoteRecord.fetchOne(db, key: record.id)?.note
        guard let transaction = WalletDatabase.walletTransaction(
            record, assetsByID: assets, networkByID: [network.id: network], localNote: note,
            primaryTransfer: transfer
        ), WalletTransactionVisibilityPolicy.includes(transaction) else { return nil }
        var resolved = notification
        resolved.walletID = walletID
        resolved.networkID = networkID
        resolved.transactionHash = hash
        resolved.relatedTransactionID = record.id
        resolved.assetSymbol = record.assetSymbol
        return NotificationTransactionContext(notification: resolved, record: record, account: account, transaction: transaction)
    }

    /// Some older writers normalized base58 hashes; current Solana/Sui writers
    /// preserve case. Query both indexed representations, then compare the real
    /// identity with the chain's case rules before associating any record.
    static func records(walletID: String, networkID: String, hash: String, in db: Database) throws -> [DBTransactionRecord] {
        let canonical = canonicalHash(hash, networkID: networkID)
        let variants = Array(Set([hash, hash.lowercased(), canonical, "0x" + canonical]))
        let placeholders = Array(repeating: "?", count: variants.count).joined(separator: ",")
        return try DBTransactionRecord.fetchAll(db, sql: """
            SELECT t.* FROM transactions t JOIN walletAccounts a ON a.id = t.accountID
            WHERE a.walletID = ? AND t.networkID = ? AND t.normalizedTransactionHash IN (\(placeholders))
            ORDER BY t.updatedAt DESC, t.id
            """, arguments: StatementArguments([walletID, networkID] + variants))
            .filter { hashesMatch($0.transactionHash, hash, networkID: networkID) }
    }

    static func hashesMatch(_ lhs: String, _ rhs: String, networkID: String) -> Bool {
        canonicalHash(lhs, networkID: networkID) == canonicalHash(rhs, networkID: networkID)
    }

    private static func canonicalHash(_ hash: String, networkID: String) -> String {
        if [SolanaConstants.networkID, SuiConstants.networkID, NEARConstants.networkID].contains(networkID) {
            return hash
        }
        let lower = hash.lowercased()
        // TRON pushes can contain an Ethereum-style prefix; indexed history does
        // not. Only hexadecimal chains accept that alternate representation.
        if networkID == TronConstants.networkID ||
            BitcoinFamilyChain(rawValue: networkID) != nil ||
            (try? SendTransactionStatusRoute.resolve(networkID: networkID)) == .evm {
            return lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
        }
        return lower
    }

    static func persist(_ status: SendTransactionNetworkStatus, context: NotificationTransactionContext,
                        database: WalletDatabase) async throws {
        try await database.pool.write { db in
            // Never undo a persisted cancellation or downgrade terminal history
            // just because a provider temporarily cannot find the transaction.
            guard let current = try DBTransactionRecord.fetchOne(db, key: context.record.id),
                  current.accountID == context.account.id, current.networkID == context.record.networkID,
                  current.transactionHash == context.record.transactionHash, current.status != "canceled",
                  status.isTerminal || current.status == "pending" else { return }
            if status.isTerminal && current.kind == "sent" {
                try WalletDatabase.deletePendingSendResources(receipt: context.receipt, database: db)
            }
            // Missing observations need the foreground monitor's repeated-read
            // policy. A notification details lookup cannot bypass that policy.
            guard status.isTerminal || status == .pending else { return }
            try db.execute(sql: "UPDATE transactions SET status = ?, updatedAt = ? WHERE id = ?",
                           arguments: [status.databaseStatus, Date().timeIntervalSince1970, current.id])
        }
    }
}
